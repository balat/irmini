(** Storage backends for Irmin.

    Backends are records of functions, NOT functors. This makes them composable
    and easy to create without functor application.

    {b Thread-safety.} Backend values are typically shared across fibers and
    potentially across domains.  The built-in backends have the following
    concurrency guarantees:

    - {!Memory}: {b not} thread-safe.  For multi-domain use, wrap with
      {!thread_safe_rw}: [thread_safe_rw (Memory.create_sha1 ())].
    - {!Disk}: internally protected by [Eio.Mutex] — safe for concurrent
      access from multiple fibers {e and} domains within an Eio event loop.
    - {!cached}: {b not} thread-safe.  Apply {e before} the thread-safety
      wrapper so the outer lock protects the cache:
      [thread_safe_rw (cached ~capacity:100_000 backend)].
    - {!thread_safe}: wraps with [Stdlib.Mutex] (exclusive). Safe for
      non-yielding backends. Do {b not} use with Eio I/O backends.
    - {!thread_safe_rw}: wraps with a read-write lock (concurrent readers,
      exclusive writer). Better than {!thread_safe} for read-heavy workloads.
      Same restriction: non-yielding backends only.
    - {!layered}, {!readonly}: inherit the thread-safety of their delegates. *)

(** {1 Backend Interface} *)

type 'hash t = {
  read : 'hash -> string option;
      (** [read hash] retrieves the object with the given hash. *)
  write : 'hash -> string -> unit;
      (** [write hash data] stores [data] at [hash]. Caller computes the hash.
      *)
  exists : 'hash -> bool;  (** [exists hash] checks if an object exists. *)
  get_ref : string -> 'hash option;
      (** [get_ref name] reads a reference (branch/tag). *)
  set_ref : string -> 'hash -> unit;
      (** [set_ref name hash] sets a reference. *)
  test_and_set_ref : string -> test:'hash option -> set:'hash option -> bool;
      (** [test_and_set_ref name ~test ~set] atomically updates a reference if
          its current value matches [test]. *)
  list_refs : unit -> string list;
      (** [list_refs ()] returns all reference names. *)
  write_batch : ('hash * string) list -> unit;
      (** [write_batch [(h1, d1); ...]] writes multiple objects efficiently. *)
  flush : unit -> unit;  (** [flush ()] ensures all writes are persisted. *)
  close : unit -> unit;  (** [close ()] releases resources. *)
}

(** {1 Memory Backend} *)

module Memory : sig
  val create_with_hash : ('h -> string) -> ('h -> 'h -> bool) -> 'h t
  (** [create_with_hash to_hex equal] creates an in-memory backend. Caller
      computes hashes; backend just stores (hash, data) pairs. *)

  val create_sha1 : ?cache:int -> unit -> Hash.sha1 t
  (** Create an in-memory SHA-1 backend. If [cache] is given, wraps with an
      LRU cache of that capacity. *)

  val create_sha256 : ?cache:int -> unit -> Hash.sha256 t
  (** Create an in-memory SHA-256 backend. If [cache] is given, wraps with an
      LRU cache of that capacity. *)
end

(** {1 Backend Combinators} *)

val default_cache_capacity : int
(** Recommended default cache capacity (100 000 entries).
    Suitable for most workloads; adjust based on memory budget and
    working set size. *)

val cached : ?capacity:int -> 'h t -> 'h t
(** [cached ?capacity backend] wraps a backend with an LRU cache (default:
    {!default_cache_capacity} entries). Reads are served from cache when
    possible, and writes populate the cache. *)

val thread_safe : 'h t -> 'h t
(** [thread_safe backend] wraps a backend with a [Mutex.t] so it can be
    safely shared across multiple domains. Each operation acquires the mutex. *)

val thread_safe_rw : 'h t -> 'h t
(** [thread_safe_rw backend] wraps a backend with a read-write lock.
    Read operations ([read], [exists], [get_ref], [list_refs]) run
    concurrently. Write operations are exclusive. Better than {!thread_safe}
    for read-heavy workloads. Only use with non-yielding backends. *)

val readonly : 'h t -> 'h t
(** [readonly backend] makes a backend read-only. Write operations raise
    [Invalid_argument]. *)

val layered : upper:'h t -> lower:'h t -> 'h t
(** [layered ~upper ~lower] creates a layered backend. Reads check upper first,
    then lower. Writes go to upper only. Used for garbage collection
    (upper=live, lower=frozen). *)

(** {1 Disk Backend} *)

module Disk : sig
  val create_with_hash :
    ?use_fsync:bool ->
    sw:Eio.Switch.t ->
    Eio.Fs.dir_ty Eio.Path.t ->
    ('h -> string) ->
    (string -> ('h, [ `Msg of string ]) result) ->
    ('h -> 'h -> bool) ->
    'h t
  (** [create_with_hash ~use_fsync ~sw root to_hex of_hex equal] creates a
      disk-based backend at [root]. When [use_fsync] is [false], WAL writes are
      not fsynced (faster but less crash-safe). Default: [true].

      Storage layout:
      - objects.data: append-only file containing all objects
      - objects.idx: index mapping hex hash to (offset, length)
      - refs/: directory with one file per ref *)

  val create_sha1 :
    ?cache:int -> ?use_fsync:bool ->
    sw:Eio.Switch.t -> Eio.Fs.dir_ty Eio.Path.t -> Hash.sha1 t
  (** Create a disk-based SHA-1 backend. If [cache] is given, wraps with an
      LRU cache of that capacity. When [use_fsync] is [false], WAL writes are
      not fsynced (faster but less crash-safe). Default: [true]. *)

  val create_sha256 :
    ?cache:int -> ?use_fsync:bool ->
    sw:Eio.Switch.t -> Eio.Fs.dir_ty Eio.Path.t -> Hash.sha256 t
  (** Create a disk-based SHA-256 backend. If [cache] is given, wraps with an
      LRU cache of that capacity. When [use_fsync] is [false], WAL writes are
      not fsynced (faster but less crash-safe). Default: [true]. *)
end

(** {1 Statistics} *)

type stats = { reads : int; writes : int; cache_hits : int; cache_misses : int }

val stats : _ t -> stats option
(** [stats backend] returns statistics if the backend tracks them. *)
