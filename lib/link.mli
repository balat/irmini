(** Link API - Persistent OCaml heap.

    Links are content-addressed references to values. They provide a minimal
    interface for persisting OCaml values to disk with lazy loading. *)

(** {1 Core Types} *)

type 'a t
(** A reference to a value of type ['a], identified by content hash. *)

type 'a link = 'a t
(** Alias for [t]. *)

(** {1 Construction} *)

val link : 'a -> 'a t
(** [link v] creates a reference to [v]. The value is kept in memory until
    persisted. *)

val of_hash : Hash.any -> 'a t
(** [of_hash h] creates a link from a known hash. The value will be fetched on
    first access. *)

(** {1 Access} *)

val fetch : 'a t -> 'a
(** [fetch l] returns the value referenced by [l]. May perform I/O if the value
    is not in memory.

    Uses algebraic effects for I/O - code using [fetch] need not be written in
    monadic style.

    @raise Effect.Unhandled if no fetch handler is installed.

    Invariants:
    - [fetch (link v) = v]
    - [link (fetch l) = l] (when [l] is reachable) *)

val fetch_opt : 'a t -> 'a option
(** [fetch_opt l] returns [Some v] if the value is available, [None] if fetching
    fails. *)

(** {1 Properties} *)

val hash : 'a t -> Hash.any
(** [hash l] returns the content hash of the linked value. Forces computation of
    the hash if not yet known. *)

val is_in_memory : 'a t -> bool
(** [is_in_memory l] returns [true] if the value is currently cached. *)

val equal : 'a t -> 'a t -> bool
(** [equal l1 l2] returns [true] iff [l1] and [l2] reference the same content.
    Equality is hash equality. *)

(** {1 Effects} *)

type _ Effect.t +=
  | Fetch : Hash.any -> string Effect.t
        (** Effect performed when [fetch] needs to read from disk/network. *)
  | Store : string -> Hash.any Effect.t
        (** Effect performed when a value needs to be persisted. *)

(** {1 Effect Handlers} *)

val with_memory_handler : (unit -> 'a) -> 'a
(** [with_memory_handler f] runs [f] with an in-memory store. Useful for
    testing. *)

val with_backend_handler : _ Backend.t -> (unit -> 'a) -> 'a
(** [with_backend_handler backend f] runs [f] with fetch/store handled by
    [backend]. *)

(** {1 Cache Control} *)

val clear_cache : 'a t -> unit
(** [clear_cache l] evicts the value from memory. Next [fetch] will re-read from
    disk. *)

val prefetch : 'a t -> unit
(** [prefetch l] starts loading the value in the background. Does nothing if
    already in memory. *)

(** {1 Stores} *)

type 'a store
(** A persistent store for values of type ['a]. *)

val create_store : string -> 'a -> 'a store
(** [create_store path init] creates a store at [path] with initial value
    [init]. *)

val open_store : string -> 'a store
(** [open_store path] opens an existing store. *)

val read : 'a store -> 'a
(** [read s] returns the root value. Subtrees load lazily via [fetch]. *)

val write : 'a store -> 'a -> unit
(** [write s v] persists [v] as the new root. Only new links are written. *)

val close : 'a store -> unit
(** [close s] releases resources. *)
