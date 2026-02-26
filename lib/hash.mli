(** Content-addressed hashes with phantom types for algorithm safety.

    This module provides SHA-1 and SHA-256 hash types that are distinguished at
    the type level, preventing accidental mixing of different hash algorithms.
*)

(** {1 Hash Algorithms} *)

type algorithm =
  | Sha1  (** SHA-1: 20 bytes, Git compatible *)
  | Sha256  (** SHA-256: 32 bytes, ATProto compatible *)

(** {1 Phantom-Typed Hashes} *)

type 'a t
(** ['a t] is a hash where ['a] is a phantom type indicating the algorithm. *)

type sha1 = [ `Sha1 ] t
(** SHA-1 hash: 20 bytes, used by Git. *)

type sha256 = [ `Sha256 ] t
(** SHA-256 hash: 32 bytes, used by ATProto MST. *)

(** {1 Hash Construction} *)

val sha1 : string -> sha1
(** [sha1 data] computes the SHA-1 hash of [data]. *)

val sha256 : string -> sha256
(** [sha256 data] computes the SHA-256 hash of [data]. *)

val sha1_of_bytes : string -> sha1
(** [sha1_of_bytes raw] creates a SHA-1 hash from raw 20-byte digest. *)

val sha256_of_bytes : string -> sha256
(** [sha256_of_bytes raw] creates a SHA-256 hash from raw 32-byte digest. *)

(** {1 Conversions} *)

val to_bytes : _ t -> string
(** [to_bytes h] returns the raw bytes of the hash digest. *)

val to_hex : _ t -> string
(** [to_hex h] returns the hexadecimal representation of the hash. *)

type existential =
  | Ex : _ t -> existential
      (** Type-erased hash returned when algorithm is only known at runtime. *)

val of_hex : algorithm -> string -> (existential, [> `Msg of string ]) result
(** [of_hex algo hex] parses a hexadecimal hash string. *)

val sha1_of_hex : string -> (sha1, [> `Msg of string ]) result
(** [sha1_of_hex hex] parses a SHA-1 hex string. *)

val sha256_of_hex : string -> (sha256, [> `Msg of string ]) result
(** [sha256_of_hex hex] parses a SHA-256 hex string. *)

(** {1 Comparison} *)

val equal : 'a t -> 'a t -> bool
(** [equal h1 h2] is [true] if [h1] and [h2] are the same hash. *)

val compare : 'a t -> 'a t -> int
(** [compare h1 h2] is a total ordering on hashes. *)

(** {1 Algorithm Info} *)

val length : _ t -> int
(** [length h] returns the byte length of the hash (20 for SHA-1, 32 for
    SHA-256). *)

val algorithm_of : _ t -> algorithm
(** [algorithm_of h] returns the algorithm used for [h]. *)

val algorithm_length : algorithm -> int
(** [algorithm_length algo] returns the byte length for [algo]. *)

(** {1 MST Support} *)

val mst_depth : sha256 -> int
(** [mst_depth h] counts leading zeros in 2-bit chunks for ATProto MST. This
    determines the tree depth for a given key hash. *)

(** {1 Type-Erased Hashes} *)

type any = Any : _ t -> any  (** Type-erased hash for mixed-hash stores. *)

val any_algorithm : any -> algorithm
(** [any_algorithm a] returns the algorithm of the erased hash. *)

val any_to_bytes : any -> string
(** [any_to_bytes a] returns the raw bytes. *)

val any_to_hex : any -> string
(** [any_to_hex a] returns the hex representation. *)

val equal_any : any -> any -> bool
(** [equal_any a1 a2] compares two type-erased hashes. *)

(** {1 Pretty Printing} *)

val pp : Format.formatter -> _ t -> unit
(** [pp fmt h] pretty-prints [h] as hex. *)

val pp_short : Format.formatter -> _ t -> unit
(** [pp_short fmt h] pretty-prints the first 7 characters of [h] (Git-style). *)
