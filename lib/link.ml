(** Persistent pointers to OCaml values. *)

(* Internal representation.
   Note: At constructor is used by of_hash_ for testing/persistence. *)
type 'a location =
  | In_memory of 'a * string
  | At of Hash.sha256
  | Both of 'a * Hash.sha256

type 'a t = 'a location ref

(* Internal: create link from hash (for persistence layer) *)
let of_hash_ h = ref (At h)

(* Effects *)
type _ Effect.t +=
  | Fetch : Hash.sha256 -> string Effect.t
  | Store : string -> Hash.sha256 Effect.t

(* Serialization *)
let encode v = Marshal.to_string v [ Marshal.No_sharing ]
let decode s = Marshal.from_string s 0

(* Links *)

let v x =
  let data = encode x in
  ref (In_memory (x, data))

let get l =
  match !l with
  | In_memory (x, _) -> x
  | Both (x, _) -> x
  | At h ->
      let data = Effect.perform (Fetch h) in
      let x = decode data in
      l := Both (x, h);
      x

let hash l =
  match !l with
  | In_memory (x, data) ->
      let h = Effect.perform (Store data) in
      l := Both (x, h);
      h
  | At h -> h
  | Both (_, h) -> h

let equal l0 l1 = Hash.equal (hash l0) (hash l1)

let is_available l =
  match !l with In_memory _ | Both _ -> true | At _ -> false

let pp ppf l =
  let h = hash l in
  Format.fprintf ppf "%s" (String.sub (Hash.to_hex h) 0 7)

(* Stores *)

type 'a store = {
  read : Hash.sha256 -> string option;
  write : string -> Hash.sha256;
  mutable root : 'a option;
  mutable open' : bool;
}

let mem () =
  let tbl = Hashtbl.create 128 in
  {
    read = (fun h -> Hashtbl.find_opt tbl (Hash.to_hex h));
    write =
      (fun data ->
        let h = Hash.sha256 data in
        Hashtbl.replace tbl (Hash.to_hex h) data;
        h);
    root = None;
    open' = true;
  }

let run (type a b) (s : a store) (f : unit -> b) : b =
  if not s.open' then failwith "Link.run: store is closed";
  let open Effect.Deep in
  try_with f ()
    {
      effc =
        (fun (type c) (eff : c Effect.t) ->
          match eff with
          | Fetch h ->
              Some
                (fun (k : (c, _) continuation) ->
                  match s.read h with
                  | None ->
                      failwith
                        (Printf.sprintf "Link.get: hash not found: %s"
                           (Hash.to_hex h))
                  | Some data -> continue k data)
          | Store data ->
              Some (fun (k : (c, _) continuation) -> continue k (s.write data))
          | _ -> None);
    }

let root s = s.root

let set_root s x =
  if not s.open' then failwith "Link.set_root: store is closed";
  s.root <- Some x

let is_open s = s.open'
let close s = s.open' <- false
