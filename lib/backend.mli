(** Storage backends for Irmin.

    Backends are records of functions, NOT functors. This makes them composable
    and easy to create without functor application. *)

(** {1 Backend Interface} *)

type 'hash t = {
  read : 'hash -> string option;
      (** [read hash] retrieves the object with the given hash. *)
  write : string -> 'hash;
      (** [write data] stores data and returns its hash. *)
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
  write_batch : string list -> 'hash list;
      (** [write_batch objects] writes multiple objects efficiently. *)
  flush : unit -> unit;  (** [flush ()] ensures all writes are persisted. *)
  close : unit -> unit;  (** [close ()] releases resources. *)
}

(** {1 Memory Backend} *)

module Memory : sig
  val create_sha1 : unit -> Hash.sha1 t
  (** Create an in-memory SHA-1 backend. *)

  val create_sha256 : unit -> Hash.sha256 t
  (** Create an in-memory SHA-256 backend. *)
end

(** {1 Backend Combinators} *)

val cached : 'h t -> 'h t
(** [cached backend] wraps a backend with an LRU cache. Reads are served from
    cache when possible. *)

val readonly : 'h t -> 'h t
(** [readonly backend] makes a backend read-only. Write operations raise
    [Invalid_argument]. *)

val layered : upper:'h t -> lower:'h t -> 'h t
(** [layered ~upper ~lower] creates a layered backend. Reads check upper first,
    then lower. Writes go to upper only. Used for garbage collection
    (upper=live, lower=frozen). *)

(** {1 Statistics} *)

type stats = { reads : int; writes : int; cache_hits : int; cache_misses : int }

val stats : _ t -> stats option
(** [stats backend] returns statistics if the backend tracks them. *)
