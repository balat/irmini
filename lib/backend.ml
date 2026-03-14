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

let default_cache_capacity = 100_000

(** Wrap a backend with an LRU cache for read operations.

    The cache itself is NOT thread-safe. When using with multiple domains,
    apply [cached] BEFORE [thread_safe] so the mutex protects the cache:
    {[let b = thread_safe (cached ~capacity:100_000 backend)]}
    Applying [cached] after [thread_safe] leaves the cache unprotected. *)
let cached ?(capacity = default_cache_capacity) (type h) (backend : h t) : h t =
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

(** In-memory backend using immutable maps.

    NOT thread-safe: concurrent access from multiple Eio domains will cause
    data races on the mutable [objects] and [refs] fields. Safe for use
    from multiple fibers on a single domain (Eio cooperative scheduling
    prevents interleaving within non-yielding operations).

    For multi-domain use, wrap with {!thread_safe}:
    For multi-domain use, wrap with {!thread_safe_rw}:
    {[let b = thread_safe_rw (Memory.create_sha1 ())]} *)
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

  let create_sha1 ?cache () =
    let b = create_with_hash Hash.to_hex Hash.equal in
    match cache with Some capacity -> cached ~capacity b | None -> b

  let create_sha256 ?cache () =
    let b = create_with_hash Hash.to_hex Hash.equal in
    match cache with Some capacity -> cached ~capacity b | None -> b
end

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

(** Wrap a backend with a [Stdlib.Mutex] for cross-domain thread safety.

    Each operation acquires the mutex, calls the underlying backend, then
    releases it. This is safe for backends whose operations do not yield
    to the Eio scheduler (e.g. {!Memory}).

    WARNING: Do NOT use with backends that perform Eio I/O (e.g. {!Disk}),
    as [Stdlib.Mutex.lock] blocks the OS thread. If fiber A holds the mutex
    and yields (I/O), and fiber B on the same domain tries to lock it, the
    domain deadlocks. The {!Disk} backend has its own [Eio.Mutex] for
    fiber-safe synchronization within a single domain. *)
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

(** Read-write lock: multiple concurrent readers, exclusive writer. *)
module RWLock = struct
  type t = {
    mutex : Mutex.t;
    cond : Condition.t;
    mutable readers : int;
    mutable writer : bool;
  }

  let create () =
    {
      mutex = Mutex.create ();
      cond = Condition.create ();
      readers = 0;
      writer = false;
    }

  let with_read t f =
    Mutex.lock t.mutex;
    while t.writer do
      Condition.wait t.cond t.mutex
    done;
    t.readers <- t.readers + 1;
    Mutex.unlock t.mutex;
    Fun.protect ~finally:(fun () ->
        Mutex.lock t.mutex;
        t.readers <- t.readers - 1;
        if t.readers = 0 then Condition.broadcast t.cond;
        Mutex.unlock t.mutex)
      f

  let with_write t f =
    Mutex.lock t.mutex;
    while t.writer || t.readers > 0 do
      Condition.wait t.cond t.mutex
    done;
    t.writer <- true;
    Mutex.unlock t.mutex;
    Fun.protect ~finally:(fun () ->
        Mutex.lock t.mutex;
        t.writer <- false;
        Condition.broadcast t.cond;
        Mutex.unlock t.mutex)
      f
end

(** [thread_safe_rw backend] wraps a backend with a read-write lock.
    Read operations ([read], [exists], [get_ref], [list_refs]) run
    concurrently. Write operations are exclusive.

    Like {!thread_safe}, only use with non-yielding backends (e.g.
    {!Memory}). Do NOT use with Eio I/O backends ({!Disk}). *)
let thread_safe_rw (backend : 'h t) : 'h t =
  let rw = RWLock.create () in
  {
    read = (fun h -> RWLock.with_read rw (fun () -> backend.read h));
    write = (fun h data -> RWLock.with_write rw (fun () -> backend.write h data));
    exists = (fun h -> RWLock.with_read rw (fun () -> backend.exists h));
    get_ref = (fun name -> RWLock.with_read rw (fun () -> backend.get_ref name));
    set_ref =
      (fun name hash ->
        RWLock.with_write rw (fun () -> backend.set_ref name hash));
    test_and_set_ref =
      (fun name ~test ~set ->
        RWLock.with_write rw (fun () ->
            backend.test_and_set_ref name ~test ~set));
    list_refs = (fun () -> RWLock.with_read rw (fun () -> backend.list_refs ()));
    write_batch =
      (fun objects ->
        RWLock.with_write rw (fun () -> backend.write_batch objects));
    flush = (fun () -> RWLock.with_write rw (fun () -> backend.flush ()));
    close = (fun () -> RWLock.with_write rw (fun () -> backend.close ()));
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

  type wal_slot = { wal : Wal.t; mutex : Eio.Mutex.t }

  (** Maximum number of WAL slots (one per domain). *)
  let max_wal_slots = 128

  type 'hash state = {
    root : Eio.Fs.dir_ty Eio.Path.t;
    mutable data_file : Eio.File.rw_ty Eio.Resource.t option;
    data_offset : int Atomic.t;
    index : index_entry String_map.t Atomic.t;
    bloom : string Bloom.t;
    bloom_mutex : Eio.Mutex.t;  (** Lightweight: protects bloom.add across domains *)
    refs : 'hash String_map.t Atomic.t;
    to_hex : 'hash -> string;
    equal : 'hash -> 'hash -> bool;
    wal_slots : wal_slot option array;  (** Per-domain WAL, indexed by domain ID *)
    sw : Eio.Switch.t;
    use_fsync : bool;
  }

  let data_path root = Eio.Path.(root / "objects.data")
  let index_path root = Eio.Path.(root / "objects.idx")
  let bloom_path root = Eio.Path.(root / "objects.bloom")
  let legacy_wal_path root = Eio.Path.(root / "objects.wal")
  let wal_path root did = Eio.Path.(root / Printf.sprintf "wal-%d.log" did)
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
    Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 path;
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
      Eio.Path.open_out ~sw ~append:false ~create:(`If_missing 0o644) path
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

  (** Get or lazily create the WAL slot for the current domain. *)
  let get_domain_wal state =
    let did = (Domain.self () :> int) in
    let did = did mod max_wal_slots in
    match state.wal_slots.(did) with
    | Some slot -> slot
    | None ->
        let wal = Wal.create ~sw:state.sw (wal_path state.root did) in
        let slot = { wal; mutex = Eio.Mutex.create () } in
        state.wal_slots.(did) <- Some slot;
        slot

  (** Collect all WAL file paths (wal-*.log + legacy objects.wal). *)
  let collect_wal_paths root =
    let paths = ref [] in
    (* Legacy WAL *)
    let legacy = legacy_wal_path root in
    if Eio.Path.is_file legacy then paths := legacy :: !paths;
    (* Per-domain WALs *)
    for did = 0 to max_wal_slots - 1 do
      let p = wal_path root did in
      if Eio.Path.is_file p then paths := p :: !paths
    done;
    !paths

  (* Replay WAL entries that aren't in the index yet *)
  let replay_wal root index bloom data_file data_offset =
    let wal_paths = collect_wal_paths root in
    List.fold_left
      (fun (idx, blm, offset) wal_p ->
        let records = Wal.read_all wal_p in
        List.fold_left
          (fun (idx, blm, offset) record ->
            match decode_wal_record record with
            | None -> (idx, blm, offset)
            | Some (hex, data) ->
                if String_map.mem hex idx then (idx, blm, offset)
                else begin
                  let len = String.length data in
                  Eio.File.pwrite_all data_file
                    ~file_offset:(Optint.Int63.of_int offset)
                    [ Cstruct.of_string data ];
                  let idx' = String_map.add hex { offset; length = len } idx in
                  Bloom.add blm hex;
                  (idx', blm, offset + len)
                end)
          (idx, blm, offset)
          records)
      (index, bloom, data_offset)
      wal_paths

  let create_with_hash (type h) ?(use_fsync = true) ~sw
      (root : Eio.Fs.dir_ty Eio.Path.t)
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
    (* Replay any uncommitted WAL entries from all WAL files *)
    let index, bloom, offset = replay_wal root index bloom data_file offset in
    let state =
      {
        root;
        data_file = Some data_file;
        data_offset = Atomic.make offset;
        index = Atomic.make index;
        bloom;
        bloom_mutex = Eio.Mutex.create ();
        refs = Atomic.make refs;
        to_hex;
        equal;
        wal_slots = Array.make max_wal_slots None;
        sw;
        use_fsync;
      }
    in
    (* CAS helper: retry until the atomic update succeeds. *)
    let cas_update : type a. a Atomic.t -> (a -> a) -> unit =
     fun atomic f ->
      let rec loop () =
        let old = Atomic.get atomic in
        let v = f old in
        if Atomic.compare_and_set atomic old v then () else loop ()
      in
      loop ()
    in
    {
      read =
        (fun h ->
          (* Lock-free: index is Atomic.t, pread is positional (thread-safe). *)
          let key = state.to_hex h in
          match String_map.find_opt key (Atomic.get state.index) with
          | None -> None
          | Some entry -> (
              match state.data_file with
              | None -> None
              | Some file ->
                  let buf = Cstruct.create entry.length in
                  Eio.File.pread_exact file
                    ~file_offset:(Optint.Int63.of_int entry.offset)
                    [ buf ];
                  Some (Cstruct.to_string buf)));
      write =
        (fun h data ->
          let key = state.to_hex h in
          (* Lock-free fast path: already present in index *)
          if String_map.mem key (Atomic.get state.index) then ()
          else
            match state.data_file with
            | Some file ->
                (* Per-domain WAL: only fibers on this domain contend *)
                let slot = get_domain_wal state in
                Eio.Mutex.use_rw ~protect:true slot.mutex (fun () ->
                    (* Re-check under lock: another fiber may have added it *)
                    if not (String_map.mem key (Atomic.get state.index)) then begin
                      Wal.append slot.wal (encode_wal_record key data);
                      if state.use_fsync then Wal.sync slot.wal
                    end);
                (* Bloom under lightweight cross-domain mutex *)
                Eio.Mutex.use_rw ~protect:true state.bloom_mutex (fun () ->
                    Bloom.add state.bloom key);
                (* Reserve space atomically, then pwrite in parallel *)
                let len = String.length data in
                let off = Atomic.fetch_and_add state.data_offset len in
                Eio.File.pwrite_all file
                  ~file_offset:(Optint.Int63.of_int off)
                  [ Cstruct.of_string data ];
                (* Update index with CAS *)
                cas_update state.index (fun idx ->
                    String_map.add key { offset = off; length = len } idx)
            | None -> ());
      exists =
        (fun h ->
          (* Lock-free: just read the atomic index *)
          let key = state.to_hex h in
          String_map.mem key (Atomic.get state.index));
      get_ref =
        (fun name ->
          (* Lock-free *)
          String_map.find_opt name (Atomic.get state.refs));
      set_ref =
        (fun name hash ->
          cas_update state.refs (fun r -> String_map.add name hash r);
          save_ref state.root name hash state.to_hex);
      test_and_set_ref =
        (fun name ~test ~set ->
          (* CAS loop on refs atomic *)
          let rec cas () =
            let old_refs = Atomic.get state.refs in
            let current = String_map.find_opt name old_refs in
            let matches =
              match (test, current) with
              | None, None -> true
              | Some t, Some c -> state.equal t c
              | _ -> false
            in
            if not matches then false
            else
              let new_refs =
                match set with
                | None -> String_map.remove name old_refs
                | Some h -> String_map.add name h old_refs
              in
              if Atomic.compare_and_set state.refs old_refs new_refs then begin
                (match set with
                | None -> delete_ref state.root name
                | Some h -> save_ref state.root name h state.to_hex);
                true
              end
              else cas ()
          in
          cas ());
      list_refs =
        (fun () ->
          (* Lock-free *)
          String_map.bindings (Atomic.get state.refs) |> List.map fst);
      write_batch =
        (fun objects ->
          match state.data_file with
          | Some file ->
              (* Snapshot index to filter out already-present keys *)
              let idx = Atomic.get state.index in
              let new_objs =
                List.filter
                  (fun (h, _data) ->
                    not (String_map.mem (state.to_hex h) idx))
                  objects
              in
              if new_objs = [] then ()
              else begin
                (* Per-domain WAL *)
                let slot = get_domain_wal state in
                Eio.Mutex.use_rw ~protect:true slot.mutex (fun () ->
                    List.iter
                      (fun (h, data) ->
                        let key = state.to_hex h in
                        Wal.append slot.wal (encode_wal_record key data))
                      new_objs;
                    if state.use_fsync then Wal.sync slot.wal);
                (* Bloom under lightweight cross-domain mutex *)
                Eio.Mutex.use_rw ~protect:true state.bloom_mutex (fun () ->
                    List.iter
                      (fun (h, _data) ->
                        Bloom.add state.bloom (state.to_hex h))
                      new_objs);
                (* Reserve total space atomically *)
                let total_len =
                  List.fold_left
                    (fun acc (_h, data) -> acc + String.length data)
                    0 new_objs
                in
                let base_off =
                  Atomic.fetch_and_add state.data_offset total_len
                in
                (* Write data at reserved offsets (no lock needed, non-overlapping) *)
                let entries =
                  let off = ref base_off in
                  List.map
                    (fun (h, data) ->
                      let key = state.to_hex h in
                      let len = String.length data in
                      let o = !off in
                      Eio.File.pwrite_all file
                        ~file_offset:(Optint.Int63.of_int o)
                        [ Cstruct.of_string data ];
                      off := o + len;
                      (key, { offset = o; length = len }))
                    new_objs
                in
                (* Update index with CAS (batch all entries at once) *)
                cas_update state.index (fun idx ->
                    List.fold_left
                      (fun acc (key, entry) -> String_map.add key entry acc)
                      idx entries)
              end
          | None -> ());
      flush =
        (fun () ->
          (match state.data_file with
          | Some file -> Eio.File.sync file
          | None -> ());
          save_index state.root (Atomic.get state.index);
          save_bloom state.root state.bloom;
          (* Close and delete all per-domain WAL files *)
          Array.iteri
            (fun i slot_opt ->
              match slot_opt with
              | Some slot ->
                  Wal.close slot.wal;
                  state.wal_slots.(i) <- None;
                  let wal_p = wal_path state.root i in
                  if Eio.Path.is_file wal_p then Eio.Path.unlink wal_p
              | None -> ())
            state.wal_slots;
          (* Also clean up legacy WAL *)
          let legacy = legacy_wal_path state.root in
          if Eio.Path.is_file legacy then Eio.Path.unlink legacy);
      close =
        (fun () ->
          (* Close all per-domain WALs *)
          Array.iteri
            (fun i slot_opt ->
              match slot_opt with
              | Some slot ->
                  Wal.close slot.wal;
                  state.wal_slots.(i) <- None
              | None -> ())
            state.wal_slots;
          (match state.data_file with
          | Some file ->
              Eio.File.sync file;
              Eio.Resource.close file
          | None -> ());
          save_index state.root (Atomic.get state.index);
          save_bloom state.root state.bloom;
          (* Delete all WAL files *)
          List.iter
            (fun p -> if Eio.Path.is_file p then Eio.Path.unlink p)
            (collect_wal_paths state.root);
          state.data_file <- None);
    }

  let create_sha1 ?cache ?(use_fsync = true) ~sw root =
    let b = create_with_hash ~use_fsync ~sw root Hash.to_hex Hash.sha1_of_hex Hash.equal in
    match cache with Some capacity -> cached ~capacity b | None -> b

  let create_sha256 ?cache ?(use_fsync = true) ~sw root =
    let b = create_with_hash ~use_fsync ~sw root Hash.to_hex Hash.sha256_of_hex Hash.equal in
    match cache with Some capacity -> cached ~capacity b | None -> b
end
