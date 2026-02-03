(** Link API - Persistent OCaml heap. *)

(** {1 Effects} *)

type _ Effect.t +=
  | Fetch : Hash.any -> string Effect.t
  | Store : string -> Hash.any Effect.t

(** {1 Internal State} *)

type 'a state =
  | Memory of 'a * string (* value and serialized form *)
  | Disk of Hash.any (* only hash known, value on disk *)
  | Both of 'a * Hash.any (* value in memory AND persisted *)

type 'a t = { mutable state : 'a state; mutable hash_cache : Hash.any option }
type 'a link = 'a t

(** {1 Serialization}

    For now, we use Marshal. In the future, this should use Typerep-based binary
    encoding for better control and stability. *)

let serialize (v : 'a) : string = Marshal.to_string v [ Marshal.No_sharing ]
let deserialize (s : string) : 'a = Marshal.from_string s 0

(** {1 Construction} *)

let link v =
  let s = serialize v in
  { state = Memory (v, s); hash_cache = None }

let of_hash h = { state = Disk h; hash_cache = Some h }

(** {1 Access} *)

let fetch t =
  match t.state with
  | Memory (v, _) -> v
  | Both (v, _) -> v
  | Disk h ->
      let s = Effect.perform (Fetch h) in
      let v = deserialize s in
      t.state <- Both (v, h);
      v

let fetch_opt t = try Some (fetch t) with _ -> None

(** {1 Properties} *)

let hash t =
  match t.hash_cache with
  | Some h -> h
  | None ->
      let h =
        match t.state with
        | Memory (_, s) ->
            let h = Effect.perform (Store s) in
            t.state <- Both (deserialize s, h);
            h
        | Disk h -> h
        | Both (_, h) -> h
      in
      t.hash_cache <- Some h;
      h

let is_in_memory t =
  match t.state with Memory _ | Both _ -> true | Disk _ -> false

let equal t1 t2 = Hash.equal_any (hash t1) (hash t2)

(** {1 Effect Handlers} *)

let with_memory_handler f =
  let store = Hashtbl.create 256 in
  let counter = ref 0 in
  Effect.Deep.match_with f ()
    {
      retc = Fun.id;
      exnc = raise;
      effc =
        (fun (type a) (eff : a Effect.t) ->
          match eff with
          | Fetch h ->
              Some
                (fun (k : (a, _) Effect.Deep.continuation) ->
                  match Hashtbl.find_opt store h with
                  | Some s -> Effect.Deep.continue k s
                  | None -> failwith "Link.fetch: hash not found")
          | Store s ->
              Some
                (fun k ->
                  (* Simple hash: just use counter for now *)
                  let h = Hash.Any (Digestif.SHA256.digest_string s) in
                  Hashtbl.replace store h s;
                  incr counter;
                  Effect.Deep.continue k h)
          | _ -> None);
    }

let with_backend_handler (type h) (backend : h Backend.t) f =
  Effect.Deep.match_with f ()
    {
      retc = Fun.id;
      exnc = raise;
      effc =
        (fun (type a) (eff : a Effect.t) ->
          match eff with
          | Fetch h ->
              Some
                (fun (k : (a, _) Effect.Deep.continuation) ->
                  match h with
                  | Hash.Any digest -> (
                      (* Convert any hash to the backend's hash type *)
                      let h' = Digestif.SHA256.to_raw_string digest in
                      match backend.read (Obj.magic h') with
                      | Some s -> Effect.Deep.continue k s
                      | None -> failwith "Link.fetch: hash not found in backend"
                      ))
          | Store s ->
              Some
                (fun k ->
                  let h = backend.write s in
                  let h' = Hash.Any (Obj.magic h) in
                  Effect.Deep.continue k h')
          | _ -> None);
    }

(** {1 Cache Control} *)

let clear_cache t =
  match t.state with
  | Both (_, h) -> t.state <- Disk h
  | Memory (_, _) ->
      (* Force persist first *)
      let h = hash t in
      t.state <- Disk h
  | Disk _ -> ()

let prefetch _t =
  (* TODO: implement background loading *)
  ()

(** {1 Stores} *)

type 'a store = {
  path : string;
  mutable root : 'a t;
  backend : Hash.any Backend.t;
}

let create_store path init =
  let backend = Backend.Memory.create_sha256 () in
  let root = link init in
  (* Persist the initial value *)
  let _ = with_backend_handler backend (fun () -> hash root) in
  { path; root; backend = Obj.magic backend }

let open_store path =
  (* TODO: implement proper file-based storage *)
  let backend = Backend.Memory.create_sha256 () in
  let root = link (Obj.magic ()) in
  (* Placeholder *)
  { path; root; backend = Obj.magic backend }

let read store = with_backend_handler store.backend (fun () -> fetch store.root)

let write store v =
  let new_root = link v in
  with_backend_handler store.backend (fun () ->
      let _ = hash new_root in
      store.root <- new_root)

let close _store =
  (* TODO: flush and release resources *)
  ()
