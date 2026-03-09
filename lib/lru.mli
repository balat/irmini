(** LRU cache with O(1) lookup, insert, and eviction.

    Uses a hashtable for lookups and a doubly-linked list for LRU ordering. *)

type ('k, 'v) t
(** A cache mapping keys of type ['k] to values of type ['v]. *)

val create : int -> ('k, 'v) t
(** [create capacity] creates a cache holding at most [capacity] entries. *)

val find : ('k, 'v) t -> 'k -> 'v option
(** [find t k] returns the value associated with [k], or [None].
    Promotes the entry to most-recently-used on hit. *)

val add : ('k, 'v) t -> 'k -> 'v -> unit
(** [add t k v] inserts or updates [k]. Evicts the least-recently-used entry
    if the cache is full. *)

val mem : ('k, 'v) t -> 'k -> bool
(** [mem t k] returns [true] if [k] is in the cache. Does not promote. *)

val clear : ('k, 'v) t -> unit
(** [clear t] removes all entries. *)
