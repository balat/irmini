(** Storage backends for Irmin.

    Backends are records of functions, NOT functors. This makes them composable
    and easy to create without functor application. *)

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

  val create_sha1 : unit -> Hash.sha1 t
  (** Create an in-memory SHA-1 backend. *)

  val create_sha256 : unit -> Hash.sha256 t
  (** Create an in-memory SHA-256 backend. *)
end

(** {1 Backend Combinators} *)

val cached : ?capacity:int -> 'h t -> 'h t
(** [cached ?capacity backend] wraps a backend with an LRU cache (default:
    100 000 entries). Reads are served from cache when possible, and writes
    populate the cache. *)

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
    sw:Eio.Switch.t ->
    Eio.Fs.dir_ty Eio.Path.t ->
    ('h -> string) ->
    (string -> ('h, [ `Msg of string ]) result) ->
    ('h -> 'h -> bool) ->
    'h t
  (** [create_with_hash ~sw root to_hex of_hex equal] creates a disk-based
      backend at [root]. Uses append-only storage for objects with an index file
      for lookups.

      Storage layout:
      - objects.data: append-only file containing all objects
      - objects.idx: index mapping hex hash to (offset, length)
      - refs/: directory with one file per ref *)

  val create_sha1 : sw:Eio.Switch.t -> Eio.Fs.dir_ty Eio.Path.t -> Hash.sha1 t
  (** Create a disk-based SHA-1 backend. *)

  val create_sha256 :
    sw:Eio.Switch.t -> Eio.Fs.dir_ty Eio.Path.t -> Hash.sha256 t
  (** Create a disk-based SHA-256 backend. *)
end

(** {1 Statistics} *)

type stats = { reads : int; writes : int; cache_hits : int; cache_misses : int }

val stats : _ t -> stats option
(** [stats backend] returns statistics if the backend tracks them. *)
