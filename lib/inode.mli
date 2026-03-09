(** Inode: structural sharing for large tree nodes.

    When a tree node has more entries than {!max_entries}, it is split into
    a trie (HAMT) of smaller nodes. Modifications only touch the affected
    bucket, giving O(log n) updates instead of O(n) re-serialization. *)

module Make (F : Codec.S) : sig
  type hash = F.hash

  val max_entries : int
  (** Maximum entries in a flat node before splitting into an inode trie. *)

  val is_inode : string -> bool
  (** [is_inode data] returns [true] if [data] is an inode tree node
      (starts with the [\x02] marker). *)

  val write : (string * F.entry) list -> backend:hash Backend.t -> hash
  (** [write entries ~backend] writes [entries] to the backend. If there are
      more than [max_entries], creates an inode trie. Otherwise writes a
      flat node. Returns the root hash. *)

  val find : backend:hash Backend.t -> hash -> string -> F.entry option
  (** [find ~backend h name] finds entry [name] starting from root [h].
      Only loads the relevant bucket, not all entries. Works transparently
      on both flat nodes and inode tries. *)

  val list_all : backend:hash Backend.t -> hash -> (string * F.entry) list
  (** [list_all ~backend h] returns all entries under root [h]. *)

  val update :
    backend:hash Backend.t ->
    hash ->
    additions:(string * F.entry) list ->
    removals:string list ->
    hash
  (** [update ~backend h ~additions ~removals] incrementally updates the
      node or inode trie at [h]. Only the affected buckets are modified.
      May promote a flat node to an inode trie or demote back. *)
end
