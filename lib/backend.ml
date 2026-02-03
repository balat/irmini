type 'hash t = {
  read : 'hash -> string option;
  write : string -> 'hash;
  exists : 'hash -> bool;
  get_ref : string -> 'hash option;
  set_ref : string -> 'hash -> unit;
  test_and_set_ref : string -> test:'hash option -> set:'hash option -> bool;
  list_refs : unit -> string list;
  write_batch : string list -> 'hash list;
  flush : unit -> unit;
  close : unit -> unit;
}

type stats = {
  reads : int;
  writes : int;
  cache_hits : int;
  cache_misses : int;
}

module Memory = struct
  module StringMap = Map.Make (String)

  type 'hash state = {
    mutable objects : string StringMap.t;
    mutable refs : 'hash StringMap.t;
    hash_fn : string -> 'hash;
    to_hex : 'hash -> string;
    equal : 'hash -> 'hash -> bool;
  }

  let create_with_hash (type h) (hash_fn : string -> h) (to_hex : h -> string)
      (equal : h -> h -> bool) : h t =
    let state =
      { objects = StringMap.empty; refs = StringMap.empty; hash_fn; to_hex; equal }
    in
    {
      read =
        (fun h ->
          let key = state.to_hex h in
          StringMap.find_opt key state.objects);
      write =
        (fun data ->
          let h = state.hash_fn data in
          let key = state.to_hex h in
          state.objects <- StringMap.add key data state.objects;
          h);
      exists =
        (fun h ->
          let key = state.to_hex h in
          StringMap.mem key state.objects);
      get_ref = (fun name -> StringMap.find_opt name state.refs);
      set_ref =
        (fun name hash -> state.refs <- StringMap.add name hash state.refs);
      test_and_set_ref =
        (fun name ~test ~set ->
          let current = StringMap.find_opt name state.refs in
          let matches =
            match (test, current) with
            | None, None -> true
            | Some t, Some c -> state.equal t c
            | _ -> false
          in
          if matches then (
            (match set with
            | None -> state.refs <- StringMap.remove name state.refs
            | Some h -> state.refs <- StringMap.add name h state.refs);
            true)
          else false);
      list_refs = (fun () -> StringMap.bindings state.refs |> List.map fst);
      write_batch =
        (fun objects ->
          List.map
            (fun data ->
              let h = state.hash_fn data in
              let key = state.to_hex h in
              state.objects <- StringMap.add key data state.objects;
              h)
            objects);
      flush = (fun () -> ());
      close = (fun () -> ());
    }

  let create_sha1 () = create_with_hash Hash.sha1 Hash.to_hex Hash.equal
  let create_sha256 () = create_with_hash Hash.sha256 Hash.to_hex Hash.equal
end

(* Simple LRU cache *)
module Lru = struct
  type ('k, 'v) t = {
    capacity : int;
    mutable items : ('k * 'v) list;
  }

  let create capacity = { capacity; items = [] }

  let find t key =
    match List.assoc_opt key t.items with
    | Some v ->
        (* Move to front *)
        t.items <- (key, v) :: List.remove_assoc key t.items;
        Some v
    | None -> None

  let add t key value =
    t.items <- (key, value) :: List.remove_assoc key t.items;
    if List.length t.items > t.capacity then
      t.items <- List.rev (List.tl (List.rev t.items))
end

let cached (type h) (backend : h t) : h t =
  let module H = struct
    type t = h

    let hash = Hashtbl.hash
    let equal a b = backend.read a = backend.read b
  end in
  let cache : (h, string) Lru.t = Lru.create 1000 in
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
  }

let readonly (backend : 'h t) : 'h t =
  let fail () = invalid_arg "Backend is read-only" in
  {
    backend with
    write = (fun _ -> fail ());
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

let stats _ = None
