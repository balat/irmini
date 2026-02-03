(** Persistent pointers to OCaml values. *)

(* Address is a hex-encoded hash - algorithm agnostic *)
type address = string

(* Stores *)

type store = {
  read : address -> string option;
  write : string -> address;
  mutable root : address option;
  mutable open' : bool;
}

(* Links embed their store reference *)

type 'a t = { store : store; mutable location : 'a location }

and 'a location =
  | In_memory of 'a (* value not yet persisted *)
  | At of address (* persisted but not in memory, needs fetch *)
  | Both of 'a * address (* in memory and persisted *)

(* Serialization - placeholder, needs repr for production *)
let encode v = Marshal.to_string v [ Marshal.No_sharing ]
let decode s = Marshal.from_string s 0

(* Links *)

let v store x = { store; location = In_memory x }
let of_address store addr = { store; location = At addr }

let get l =
  match l.location with
  | In_memory x | Both (x, _) -> x
  | At addr -> (
      match l.store.read addr with
      | None -> failwith (Printf.sprintf "Link.get: address not found: %s" addr)
      | Some data ->
          let x = decode data in
          l.location <- Both (x, addr);
          x)

let address l =
  match l.location with
  | In_memory x ->
      let data = encode x in
      let addr = l.store.write data in
      l.location <- Both (x, addr);
      addr
  | At addr | Both (_, addr) -> addr

let equal l0 l1 = address l0 = address l1

let is_val l =
  match l.location with In_memory _ | Both _ -> true | At _ -> false

let pp ppf l =
  match l.location with
  | In_memory _ -> Format.fprintf ppf "<mem>"
  | At addr | Both (_, addr) ->
      Format.fprintf ppf "%s" (String.sub addr 0 (min 7 (String.length addr)))

(* Store operations *)

let root (type a) (s : store) : a option =
  match s.root with
  | None -> None
  | Some addr -> (
      match s.read addr with
      | None ->
          failwith (Printf.sprintf "Link.root: address not found: %s" addr)
      | Some data -> Some (decode data))

let set_root (type a) (s : store) (x : a) : unit =
  if not s.open' then failwith "Link.set_root: store is closed";
  let data = encode x in
  let addr = s.write data in
  s.root <- Some addr

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
          let addr = F.hash_to_hex (F.hash_contents data) in
          Hashtbl.replace tbl addr data;
          addr);
      root = None;
      open' = true;
    }
end

module Git = Make (Tree_format.Git)
module Mst = Make (Tree_format.Mst)
