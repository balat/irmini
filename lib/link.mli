(** Persistent pointers to OCaml values.

    Links delimit serialization boundaries in data structures. Insert [v] calls
    to control persistence granularity - only new links are written.

    {[
      type tree = node t
      and node = Empty | Node of { l : tree; x : int; r : tree }

      let rec add x t =
        match get t with
        | Empty -> v (Node { l = v Empty; x; r = v Empty })
        | Node n ->
            if x = n.x then t
            else if x < n.x then v (Node { n with l = add x n.l })
            else v (Node { n with r = add x n.r })
    ]}

    Properties: [get (v x) = x] and [equal (v (get l)) l]. *)

(** {1:links Links} *)

type 'a t
(** The type for links to ['a] values. *)

type hash
(** The type for content hashes. Opaque. *)

val v : 'a -> 'a t
(** [v x] is a link to [x]. *)

val get : 'a t -> 'a
(** [get l] is the value linked by [l]. May perform I/O via effects. *)

val hash : 'a t -> hash
(** [hash l] is the content hash of [l]. *)

val equal : 'a t -> 'a t -> bool
(** [equal l0 l1] is [true] iff [l0] and [l1] have the same hash. *)

val is_val : 'a t -> bool
(** [is_val l] is [true] if the value is in memory (like {!Lazy.is_val}). *)

val pp : Format.formatter -> 'a t -> unit
(** [pp] formats the link's hash. *)

(** {1:stores Stores} *)

type store
(** The type for stores. *)

val run : store -> (unit -> 'a) -> 'a
(** [run s f] runs [f] with [s] handling link effects. *)

val root : store -> 'a option
(** [root s] is the current root of [s]. *)

val set_root : store -> 'a -> unit
(** [set_root s x] sets the root of [s] to [x]. *)

val is_open : store -> bool
(** [is_open s] is [true] if [s] is open. *)

val close : store -> unit
(** [close s] closes [s]. Further operations return [None] or raise. *)

(** {2 Store creation} *)

module Make (F : Tree_format.S) : sig
  val mem : unit -> store
  (** [mem ()] is a new in-memory store using format [F]. *)
end

module Git : sig
  val mem : unit -> store
  (** [mem ()] is a new in-memory Git-compatible store (SHA-1). *)
end

module Mst : sig
  val mem : unit -> store
  (** [mem ()] is a new in-memory MST store (SHA-256, ATProto). *)
end
