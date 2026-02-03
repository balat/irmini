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

val v : 'a -> 'a t
(** [v x] is a link to [x]. *)

val get : 'a t -> 'a
(** [get l] is the value linked by [l]. May perform I/O via effects. *)

val hash : 'a t -> Hash.sha256
(** [hash l] is the content hash of [l]. Persists if needed. *)

val equal : 'a t -> 'a t -> bool
(** [equal l0 l1] is [true] iff [l0] and [l1] have the same {!hash}. *)

val is_available : 'a t -> bool
(** [is_available l] is [true] if {!get} won't perform I/O. *)

val pp : Format.formatter -> 'a t -> unit
(** [pp] formats the link's hash. *)

(** {1:stores Stores} *)

type 'a store
(** The type for stores with root type ['a]. *)

val mem : unit -> 'a store
(** [mem ()] is a new in-memory store. *)

val run : 'a store -> (unit -> 'b) -> 'b
(** [run s f] runs [f] with [s] handling link effects. *)

val root : 'a store -> 'a option
(** [root s] is the current root of [s]. *)

val set_root : 'a store -> 'a -> unit
(** [set_root s x] sets the root of [s] to [x]. *)

val is_open : 'a store -> bool
(** [is_open s] is [true] if [s] is open. *)

val close : 'a store -> unit
(** [close s] closes [s]. Further operations return [None] or raise. *)

(**/**)

(* Internal, for persistence layer *)
val of_hash_ : Hash.sha256 -> 'a t
