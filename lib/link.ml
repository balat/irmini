(** Persistent pointers to OCaml values. *)

(* Hash is stored as hex string internally - algorithm agnostic *)
type hash = string

(* Internal representation *)
type 'a location =
  | In_memory of 'a * string (* value and serialized data *)
  | At of hash (* hash only, needs fetch *)
  | Both of 'a * hash (* value and hash *)

type 'a t = 'a location ref

(* Effects *)
type _ Effect.t +=
  | Fetch : hash -> string Effect.t
  | Store : string -> hash Effect.t

(* Serialization *)
let encode v = Marshal.to_string v [ Marshal.No_sharing ]
let decode s = Marshal.from_string s 0

(* Links *)

let v x =
  let _data = encode x in
  ref (In_memory (x, _data))

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
  | In_memory (_, data) ->
      let h = Effect.perform (Store data) in
      let x = decode data in
      l := Both (x, h);
      h
  | At h -> h
  | Both (_, h) -> h

let equal l0 l1 = hash l0 = hash l1
let is_val l = match !l with In_memory _ | Both _ -> true | At _ -> false

let pp ppf l =
  match !l with
  | In_memory _ -> Format.fprintf ppf "<mem>"
  | At h | Both (_, h) ->
      Format.fprintf ppf "%s" (String.sub h 0 (min 7 (String.length h)))

(* Stores *)

type store = {
  read : hash -> string option;
  write : string -> hash;
  mutable root : Obj.t option;
  mutable open' : bool;
}

let run (type a) (s : store) (f : unit -> a) : a =
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
                      failwith (Printf.sprintf "Link.get: hash not found: %s" h)
                  | Some data -> continue k data)
          | Store data ->
              Some
                (fun (k : (c, _) continuation) ->
                  let h = s.write data in
                  continue k h)
          | _ -> None);
    }

let root (type a) (s : store) : a option = Option.map Obj.obj s.root

let set_root (type a) (s : store) (x : a) : unit =
  if not s.open' then failwith "Link.set_root: store is closed";
  s.root <- Some (Obj.repr x)

let is_open s = s.open'
let close s = s.open' <- false

(* Store creation functor *)

module Make (F : Tree_format.S) = struct
  let mem () =
    let tbl = Hashtbl.create 128 in
    {
      read = Hashtbl.find_opt tbl;
      write =
        (fun data ->
          let h = F.hash_to_hex (F.hash_contents data) in
          Hashtbl.replace tbl h data;
          h);
      root = None;
      open' = true;
    }
end

module Git = Make (Tree_format.Git)
module Mst = Make (Tree_format.Mst)
