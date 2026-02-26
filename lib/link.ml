(** Persistent pointers to OCaml values. *)

(* Address is a hex-encoded hash - algorithm agnostic *)
type address = string

(* Content store - fetch/persist functions shared by links *)
type content_store = {
  fetch : address -> string option;
  persist : string -> address;
}

(* Links embed their content store *)

type 'a t = { content : content_store; mutable location : 'a location }

and 'a location =
  | In_memory of 'a (* value not yet persisted *)
  | At of address (* persisted but not in memory, needs fetch *)
  | Both of 'a * address (* in memory and persisted *)

(* Stores - parameterized by root type *)

type 'a store = {
  content : content_store;
  mutable root : 'a option;
  mutable open' : bool;
}

(* Serialization - placeholder, needs repr for production *)
let encode v = Marshal.to_string v [ Marshal.No_sharing ]
let decode s = Marshal.from_string s 0

(* Links *)

let v (s : _ store) x = { content = s.content; location = In_memory x }
let of_address (s : _ store) addr = { content = s.content; location = At addr }

let get l =
  match l.location with
  | In_memory x | Both (x, _) -> x
  | At addr -> (
      match l.content.fetch addr with
      | None -> Fmt.failwith "Link.get: address not found: %s" addr
      | Some data ->
          let x = decode data in
          l.location <- Both (x, addr);
          x)

let address l =
  match l.location with
  | In_memory x ->
      let data = encode x in
      let addr = l.content.persist data in
      l.location <- Both (x, addr);
      addr
  | At addr | Both (_, addr) -> addr

let equal l0 l1 = address l0 = address l1

let is_val l =
  match l.location with In_memory _ | Both _ -> true | At _ -> false

let pp ppf l =
  match l.location with
  | In_memory _ -> Fmt.string ppf "<mem>"
  | At addr | Both (_, addr) ->
      Fmt.string ppf (String.sub addr 0 (min 7 (String.length addr)))

(* Store operations *)

let read (s : 'a store) : 'a =
  match s.root with Some x -> x | None -> failwith "Link.read: no root set"

let write (s : 'a store) (x : 'a) : unit =
  if not s.open' then failwith "Link.write: store is closed";
  s.root <- Some x

let is_open s = s.open'
let close s = s.open' <- false

(* Store creation functor *)

module Make (F : Codec.S) = struct
  let v () =
    let tbl = Hashtbl.create 128 in
    let content =
      {
        fetch = Hashtbl.find_opt tbl;
        persist =
          (fun data ->
            let addr = F.hash_to_hex (F.hash_contents data) in
            Hashtbl.replace tbl addr data;
            addr);
      }
    in
    { content; root = None; open' = true }
end

module Git = Make (Codec.Git)
module Mst = Make (Codec.Mst)
