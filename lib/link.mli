(** Persistent pointers to OCaml values.

    Links delimit serialization boundaries in data structures. Insert [v] calls
    to control persistence granularity - only new links are written.

    {[
      type tree = node t
      and node = Empty | Node of { l : tree; x : int; r : tree }

      let rec add s x t =
        match get t with
        | Empty -> v s (Node { l = v s Empty; x; r = v s Empty })
        | Node n ->
            if x = n.x then t
            else if x < n.x then v s (Node { n with l = add s x n.l })
            else v s (Node { n with r = add s x n.r })
    ]}

    Properties: [get (v s x) = x] and [equal (v s (get l)) l]. *)

(** {1:types Types} *)

type 'a t
(** The type for links to ['a] values. Links embed their content store. *)

type 'a store
(** The type for stores with root of type ['a]. *)

type address
(** The type for content addresses. Opaque. *)

(** {1:links Links} *)

val v : _ store -> 'a -> 'a t
(** [v s x] is a link to [x], using content store from [s]. *)

val of_address : _ store -> address -> 'a t
(** [of_address s addr] is a link that lazily loads from [addr]. *)

val get : 'a t -> 'a
(** [get l] is the value linked by [l]. Fetches if needed. *)

val address : 'a t -> address
(** [address l] is the content address of [l]. Writes if needed. *)

val equal : 'a t -> 'a t -> bool
(** [equal l0 l1] is [true] iff [l0] and [l1] have the same address. *)

val is_val : 'a t -> bool
(** [is_val l] is [true] if the value is in memory (like {!Lazy.is_val}). *)

val pp : Format.formatter -> 'a t -> unit
(** [pp] formats the link's address (or ["<mem>"] if not yet stored). *)

(** {1:stores Stores} *)

val read : 'a store -> 'a
(** [read s] is the current root of [s]. Raises if no root set. *)

val write : 'a store -> 'a -> unit
(** [write s x] sets the root of [s] to [x]. *)

val is_open : _ store -> bool
(** [is_open s] is [true] if [s] is open. *)

val close : _ store -> unit
(** [close s] closes [s]. Further operations raise. *)

(** {2 Store creation} *)

module Make (_ : Codec.S) : sig
  val v : unit -> _ store
  (** [v ()] is a new in-memory store. *)
end

module Git : sig
  val v : unit -> _ store
  (** [v ()] is a new in-memory Git-compatible store (SHA-1). *)
end

module Mst : sig
  val v : unit -> _ store
  (** [v ()] is a new in-memory MST store (SHA-256, ATProto). *)
end
