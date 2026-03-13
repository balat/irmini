type 'hash t = {
  read : 'hash -> string option;
  write : 'hash -> string -> unit;
  exists : 'hash -> bool;
  get_ref : string -> 'hash option;
  set_ref : string -> 'hash -> unit;
  test_and_set_ref : string -> test:'hash option -> set:'hash option -> bool;
  list_refs : unit -> string list;
  write_batch : ('hash * string) list -> unit;
  flush : unit -> unit;
  close : unit -> unit;
}

type stats = { reads : int; writes : int; cache_hits : int; cache_misses : int }

module Memory = struct
  module String_map = Map.Make (String)

  type 'hash state = {
    mutable objects : string String_map.t;
    mutable refs : 'hash String_map.t;
    to_hex : 'hash -> string;
    equal : 'hash -> 'hash -> bool;
  }

  let create_with_hash (type h) (to_hex : h -> string) (equal : h -> h -> bool)
      : h t =
    let state =
      { objects = String_map.empty; refs = String_map.empty; to_hex; equal }
    in
    {
      read =
        (fun h ->
          let key = state.to_hex h in
          String_map.find_opt key state.objects);
      write =
        (fun h data ->
          let key = state.to_hex h in
          state.objects <- String_map.add key data state.objects);
      exists =
        (fun h ->
          let key = state.to_hex h in
          String_map.mem key state.objects);
      get_ref = (fun name -> String_map.find_opt name state.refs);
      set_ref =
        (fun name hash -> state.refs <- String_map.add name hash state.refs);
      test_and_set_ref =
        (fun name ~test ~set ->
          let current = String_map.find_opt name state.refs in
          let matches =
            match (test, current) with
            | None, None -> true
            | Some t, Some c -> state.equal t c
            | _ -> false
          in
          if matches then (
            (match set with
            | None -> state.refs <- String_map.remove name state.refs
            | Some h -> state.refs <- String_map.add name h state.refs);
            true)
          else false);
      list_refs = (fun () -> String_map.bindings state.refs |> List.map fst);
      write_batch =
        (fun objects ->
          List.iter
            (fun (h, data) ->
              let key = state.to_hex h in
              state.objects <- String_map.add key data state.objects)
            objects);
      flush = (fun () -> ());
      close = (fun () -> ());
    }

  let create_sha1 () = create_with_hash Hash.to_hex Hash.equal
  let create_sha256 () = create_with_hash Hash.to_hex Hash.equal
end

let cached ?(capacity = 100_000) (type h) (backend : h t) : h t =
  let cache : (h, string) Lru.t = Lru.create capacity in
  {
    backend with
    read =
      (fun h ->
        match Lru.find cache h with
        | Some v -> Some v
        | None ->
            let result = backend.read h in
            Option.iter (fun v -> Lru.add cache h v) result;
            result);
    write =
      (fun h data ->
        backend.write h data;
        Lru.add cache h data);
    write_batch =
      (fun objects ->
        backend.write_batch objects;
        List.iter (fun (h, data) -> Lru.add cache h data) objects);
  }

let readonly (backend : 'h t) : 'h t =
  let fail () = invalid_arg "Backend is read-only" in
  {
    backend with
    write = (fun _ _ -> fail ());
    set_ref = (fun _ _ -> fail ());
    test_and_set_ref = (fun _ ~test:_ ~set:_ -> fail ());
    write_batch = (fun _ -> fail ());
  }

let layered ~(upper : 'h t) ~(lower : 'h t) : 'h t =
  {
    read =
      (fun h ->
        match upper.read h with Some v -> Some v | None -> lower.read h);
    write = upper.write;
    exists = (fun h -> upper.exists h || lower.exists h);
    get_ref =
      (fun name ->
        match upper.get_ref name with
        | Some v -> Some v
        | None -> lower.get_ref name);
    set_ref = upper.set_ref;
    test_and_set_ref = upper.test_and_set_ref;
    list_refs =
      (fun () ->
        let upper_refs = upper.list_refs () in
        let lower_refs = lower.list_refs () in
        List.sort_uniq String.compare (upper_refs @ lower_refs));
    write_batch = upper.write_batch;
    flush =
      (fun () ->
        upper.flush ();
        lower.flush ());
    close =
      (fun () ->
        upper.close ();
        lower.close ());
  }

let thread_safe (backend : 'h t) : 'h t =
  let m = Mutex.create () in
  let with_lock f =
    Mutex.lock m;
    Fun.protect ~finally:(fun () -> Mutex.unlock m) f
  in
  {
    read = (fun h -> with_lock (fun () -> backend.read h));
    write = (fun h data -> with_lock (fun () -> backend.write h data));
    exists = (fun h -> with_lock (fun () -> backend.exists h));
    get_ref = (fun name -> with_lock (fun () -> backend.get_ref name));
    set_ref = (fun name hash -> with_lock (fun () -> backend.set_ref name hash));
    test_and_set_ref =
      (fun name ~test ~set ->
        with_lock (fun () -> backend.test_and_set_ref name ~test ~set));
    list_refs = (fun () -> with_lock (fun () -> backend.list_refs ()));
    write_batch =
      (fun objects -> with_lock (fun () -> backend.write_batch objects));
    flush = (fun () -> with_lock (fun () -> backend.flush ()));
    close = (fun () -> with_lock (fun () -> backend.close ()));
  }

let stats _ = None

(** Disk-based backend using append-only storage with WAL and bloom filter.

    Storage layout:
    - objects.wal: write-ahead log for crash recovery (uses ocaml-wal)
    - objects.data: append-only file containing all objects
    - objects.idx: index file mapping hex hash -> (offset, length)
    - objects.bloom: serialized bloom filter for fast negative lookups
    - refs/: directory with one file per ref containing hex hash

    Write path: 1. Write to WAL (crash-safe with CRC) 2. Write to data file 3.
    Update in-memory index and bloom filter 4. On flush: save index and bloom,
    then clear WAL

    Recovery: 1. Load index and bloom from disk 2. Replay any entries in WAL not
    yet in index

    Inspired by lavyek's append-only design and LevelDB's WAL pattern. *)
module Disk = struct
  module String_map = Map.Make (String)

  type index_entry = { offset : int; length : int }

  type 'hash state = {
    root : Eio.Fs.dir_ty Eio.Path.t;
    mutable wal : Wal.t option;
    mutable data_file : Eio.File.rw_ty Eio.Resource.t option;
    mutable data_offset : int;
    mutable index : index_entry String_map.t;
    bloom : string Bloom.t;
    mutable refs : 'hash String_map.t;
    to_hex : 'hash -> string;
    equal : 'hash -> 'hash -> bool;
    mutex : Eio.Mutex.t;
  }

  let data_path root = Eio.Path.(root / "objects.data")
  let index_path root = Eio.Path.(root / "objects.idx")
  let bloom_path root = Eio.Path.(root / "objects.bloom")
  let wal_path root = Eio.Path.(root / "objects.wal")
  let refs_path root = Eio.Path.(root / "refs")

  (* Expected number of objects for bloom filter sizing *)
  let bloom_expected_size = 100_000

  (* Index file format: one line per entry "hex_hash offset length\n" *)
  let load_index root =
    let path = index_path root in
    if Eio.Path.is_file path then
      Eio.Path.load path |> String.split_on_char '\n'
      |> List.fold_left
           (fun idx line ->
             if String.length line = 0 then idx
             else
               match String.split_on_char ' ' line with
               | [ hex; off_s; len_s ] ->
                   let offset = int_of_string off_s in
                   let length = int_of_string len_s in
                   String_map.add hex { offset; length } idx
               | _ -> idx)
           String_map.empty
    else String_map.empty

  let save_index root index =
    let path = index_path root in
    let tmp_path = Eio.Path.(root / "objects.idx.tmp") in
    let content =
      String_map.fold
        (fun hex entry acc ->
          Fmt.str "%s %d %d\n" hex entry.offset entry.length :: acc)
        index []
      |> String.concat ""
    in
    Eio.Path.save ~create:(`Or_truncate 0o644) tmp_path content;
    Eio.Path.rename tmp_path path

  let load_bloom root =
    let path = bloom_path root in
    if Eio.Path.is_file path then
      match Bloom.of_bytes (Bytes.of_string (Eio.Path.load path)) with
      | Ok bloom -> bloom
      | Error _ -> Bloom.v bloom_expected_size
    else Bloom.v bloom_expected_size

  let save_bloom root bloom =
    let path = bloom_path root in
    let tmp_path = Eio.Path.(root / "objects.bloom.tmp") in
    Eio.Path.save ~create:(`Or_truncate 0o644) tmp_path
      (Bytes.to_string (Bloom.to_bytes bloom));
    Eio.Path.rename tmp_path path

  let load_ref of_hex acc full_name entry_path =
    let hex = String.trim (Eio.Path.load entry_path) in
    match of_hex hex with
    | Ok hash -> String_map.add full_name hash acc
    | Error _ -> acc

  let load_refs root of_hex =
    let refs_root = refs_path root in
    if not (Eio.Path.is_directory refs_root) then String_map.empty
    else
      let rec scan_dir prefix path acc =
        let entries = Eio.Path.read_dir path in
        List.fold_left
          (fun acc name ->
            let entry_path = Eio.Path.(path / name) in
            let full_name = if prefix = "" then name else prefix ^ "/" ^ name in
            if Eio.Path.is_file entry_path then
              load_ref of_hex acc full_name entry_path
            else if Eio.Path.is_directory entry_path then
              scan_dir full_name entry_path acc
            else acc)
          acc entries
      in
      scan_dir "" refs_root String_map.empty

  let save_ref root name hash to_hex =
    let path = refs_path root in
    if not (Eio.Path.is_directory path) then Eio.Path.mkdir ~perm:0o755 path;
    let ref_path = Eio.Path.(path / name) in
    (* Handle nested paths like refs/heads/main *)
    let dir = Filename.dirname name in
    if dir <> "." && dir <> "" then begin
      let dir_path = Eio.Path.(path / dir) in
      if not (Eio.Path.is_directory dir_path) then
        Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 dir_path
    end;
    Eio.Path.save ~create:(`Or_truncate 0o644) ref_path (to_hex hash ^ "\n")

  let delete_ref root name =
    let ref_path = Eio.Path.(refs_path root / name) in
    if Eio.Path.is_file ref_path then Eio.Path.unlink ref_path

  let open_data_file ~sw root =
    let path = data_path root in
    let file =
      Eio.Path.open_out ~sw ~append:true ~create:(`If_missing 0o644) path
    in
    let offset =
      if Eio.Path.is_file path then
        let stat = Eio.Path.stat ~follow:true path in
        Optint.Int63.to_int stat.size
      else 0
    in
    (file, offset)

  (* WAL record format: "hex_hash\x00data" *)
  let encode_wal_record hex data = hex ^ "\x00" ^ data

  let decode_wal_record record =
    match String.index_opt record '\x00' with
    | None -> None
    | Some i ->
        let hex = String.sub record 0 i in
        let data = String.sub record (i + 1) (String.length record - i - 1) in
        Some (hex, data)

  (* Replay WAL entries that aren't in the index yet *)
  let replay_wal root index bloom data_file data_offset =
    let wal_p = wal_path root in
    if not (Eio.Path.is_file wal_p) then (index, bloom, data_offset)
    else
      let records = Wal.read_all wal_p in
      List.fold_left
        (fun (idx, blm, offset) record ->
          match decode_wal_record record with
          | None -> (idx, blm, offset)
          | Some (hex, data) ->
              if String_map.mem hex idx then (idx, blm, offset)
              else begin
                (* Write to data file *)
                let len = String.length data in
                Eio.File.pwrite_all data_file
                  ~file_offset:(Optint.Int63.of_int offset)
                  [ Cstruct.of_string data ];
                let idx' = String_map.add hex { offset; length = len } idx in
                Bloom.add blm hex;
                (idx', blm, offset + len)
              end)
        (index, bloom, data_offset)
        records

  let create_with_hash (type h) ~sw (root : Eio.Fs.dir_ty Eio.Path.t)
      (to_hex : h -> string) (of_hex : string -> (h, [ `Msg of string ]) result)
      (equal : h -> h -> bool) : h t =
    (* Create root directory if needed *)
    if not (Eio.Path.is_directory root) then
      Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 root;
    let index = load_index root in
    let bloom = load_bloom root in
    (* Populate bloom from index if empty (first load after upgrade) *)
    if Bloom.size_estimate bloom = 0 then
      String_map.iter (fun hex _ -> Bloom.add bloom hex) index;
    let refs = load_refs root of_hex in
    let file, offset = open_data_file ~sw root in
    let data_file = (file :> Eio.File.rw_ty Eio.Resource.t) in
    (* Replay any uncommitted WAL entries *)
    let index, bloom, offset = replay_wal root index bloom data_file offset in
    (* Open WAL for new writes *)
    let wal = Wal.create ~sw (wal_path root) in
    let state =
      {
        root;
        wal = Some wal;
        data_file = Some data_file;
        data_offset = offset;
        index;
        bloom;
        refs;
        to_hex;
        equal;
        mutex = Eio.Mutex.create ();
      }
    in
    {
      read =
        (fun h ->
          Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
              let key = state.to_hex h in
              match String_map.find_opt key state.index with
              | None -> None
              | Some entry -> (
                  match state.data_file with
                  | None -> None
                  | Some file ->
                      let buf = Cstruct.create entry.length in
                      Eio.File.pread_exact file
                        ~file_offset:(Optint.Int63.of_int entry.offset)
                        [ buf ];
                      Some (Cstruct.to_string buf))));
      write =
        (fun h data ->
          Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
              let key = state.to_hex h in
              (* Fast path: bloom filter says "definitely not present" *)
              if Bloom.mem state.bloom key && String_map.mem key state.index
              then ()
              else
                match (state.wal, state.data_file) with
                | Some wal, Some file ->
                    (* Write to WAL first for crash safety *)
                    Wal.append wal (encode_wal_record key data);
                    Wal.sync wal;
                    (* Then write to data file *)
                    let len = String.length data in
                    let offset = state.data_offset in
                    Eio.File.pwrite_all file
                      ~file_offset:(Optint.Int63.of_int offset)
                      [ Cstruct.of_string data ];
                    state.data_offset <- offset + len;
                    state.index <-
                      String_map.add key { offset; length = len } state.index;
                    Bloom.add state.bloom key
                | _ -> ()));
      exists =
        (fun h ->
          Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
              let key = state.to_hex h in
              Bloom.mem state.bloom key && String_map.mem key state.index));
      get_ref =
        (fun name ->
          Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
              String_map.find_opt name state.refs));
      set_ref =
        (fun name hash ->
          Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
              state.refs <- String_map.add name hash state.refs;
              save_ref state.root name hash state.to_hex));
      test_and_set_ref =
        (fun name ~test ~set ->
          Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
              let current = String_map.find_opt name state.refs in
              let matches =
                match (test, current) with
                | None, None -> true
                | Some t, Some c -> state.equal t c
                | _ -> false
              in
              if matches then begin
                (match set with
                | None ->
                    state.refs <- String_map.remove name state.refs;
                    delete_ref state.root name
                | Some h ->
                    state.refs <- String_map.add name h state.refs;
                    save_ref state.root name h state.to_hex);
                true
              end
              else false));
      list_refs =
        (fun () ->
          Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
              String_map.bindings state.refs |> List.map fst));
      write_batch =
        (fun objects ->
          Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
              match (state.wal, state.data_file) with
              | Some wal, Some file ->
                  (* Write all to WAL first *)
                  List.iter
                    (fun (h, data) ->
                      let key = state.to_hex h in
                      if not (String_map.mem key state.index) then
                        Wal.append wal (encode_wal_record key data))
                    objects;
                  Wal.sync wal;
                  (* Then write to data file *)
                  List.iter
                    (fun (h, data) ->
                      let key = state.to_hex h in
                      if String_map.mem key state.index then ()
                      else begin
                        let len = String.length data in
                        let offset = state.data_offset in
                        Eio.File.pwrite_all file
                          ~file_offset:(Optint.Int63.of_int offset)
                          [ Cstruct.of_string data ];
                        state.data_offset <- offset + len;
                        state.index <-
                          String_map.add key { offset; length = len }
                            state.index;
                        Bloom.add state.bloom key
                      end)
                    objects
              | _ -> ()));
      flush =
        (fun () ->
          Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
              (match state.data_file with
              | Some file -> Eio.File.sync file
              | None -> ());
              save_index state.root state.index;
              save_bloom state.root state.bloom;
              (* Clear WAL after persisting index - entries are now recoverable
                 from index + data file *)
              let wal_p = wal_path state.root in
              if Eio.Path.is_file wal_p then Eio.Path.unlink wal_p));
      close =
        (fun () ->
          Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
              (match state.wal with Some wal -> Wal.close wal | None -> ());
              (match state.data_file with
              | Some file ->
                  Eio.File.sync file;
                  Eio.Resource.close file
              | None -> ());
              save_index state.root state.index;
              save_bloom state.root state.bloom;
              (* Clear WAL *)
              let wal_p = wal_path state.root in
              if Eio.Path.is_file wal_p then Eio.Path.unlink wal_p;
              state.wal <- None;
              state.data_file <- None));
    }

  let create_sha1 ~sw root =
    create_with_hash ~sw root Hash.to_hex Hash.sha1_of_hex Hash.equal

  let create_sha256 ~sw root =
    create_with_hash ~sw root Hash.to_hex Hash.sha256_of_hex Hash.equal
end
