(** Irmin4 backend using Lavyek as the underlying KV store.

    Objects are stored in a Lavyek database keyed by hex hash.
    Refs are stored with a "ref:" prefix to distinguish them from objects. *)

open Irmin

let ref_prefix = "ref:"

let create_with_hash ~sw root to_hex of_hex equal : _ Backend.t =
  let db = Lavyek.create ~sw root in
  (* Mutex to protect test_and_set_ref atomicity: the read-then-write
     sequence must not be interleaved with concurrent ref modifications. *)
  let ref_mutex = Eio.Mutex.create () in
  {
    read = (fun h -> Lavyek.find db ~key:(to_hex h));
    write = (fun h data -> Lavyek.put db (to_hex h) data);
    exists = (fun h -> Option.is_some (Lavyek.find db ~key:(to_hex h)));
    get_ref =
      (fun name ->
        match Lavyek.find db ~key:(ref_prefix ^ name) with
        | None -> None
        | Some hex -> (
            match of_hex hex with Ok h -> Some h | Error _ -> None));
    set_ref =
      (fun name hash ->
        Eio.Mutex.use_rw ~protect:true ref_mutex (fun () ->
            Lavyek.put db (ref_prefix ^ name) (to_hex hash)));
    test_and_set_ref =
      (fun name ~test ~set ->
        Eio.Mutex.use_rw ~protect:true ref_mutex (fun () ->
            let current =
              match Lavyek.find db ~key:(ref_prefix ^ name) with
              | None -> None
              | Some hex -> (
                  match of_hex hex with Ok h -> Some h | Error _ -> None)
            in
            let matches =
              match (test, current) with
              | None, None -> true
              | Some t, Some c -> equal t c
              | _ -> false
            in
            if matches then (
              (match set with
              | None -> Lavyek.remove db (ref_prefix ^ name)
              | Some h -> Lavyek.put db (ref_prefix ^ name) (to_hex h));
              true)
            else false));
    list_refs =
      (fun () ->
        Lavyek.list db
        |> List.filter_map (fun (k, _v) ->
               let plen = String.length ref_prefix in
               if String.length k > plen && String.sub k 0 plen = ref_prefix
               then Some (String.sub k plen (String.length k - plen))
               else None));
    write_batch =
      (fun objects ->
        List.iter (fun (h, data) -> Lavyek.put db (to_hex h) data) objects);
    flush = (fun () -> ());
    close = (fun () -> Lavyek.close db);
  }

let create_sha1 ~sw root =
  create_with_hash ~sw root Hash.to_hex Hash.sha1_of_hex Hash.equal

let create_sha256 ~sw root =
  create_with_hash ~sw root Hash.to_hex Hash.sha256_of_hex Hash.equal

let create = create_sha1
