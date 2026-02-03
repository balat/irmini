(** Commit objects.

    Commits point to a tree and have metadata like author, message, timestamp.
*)

(** {1 Commit Functor} *)

module Make (F : Tree_format.S) : sig
  type t
  (** A commit object. *)

  type hash = F.hash

  (** {2 Commit Fields} *)

  val tree : t -> hash
  (** [tree c] returns the root tree hash. *)

  val parents : t -> hash list
  (** [parents c] returns parent commit hashes. *)

  val author : t -> string
  (** [author c] returns the author string. *)

  val committer : t -> string
  (** [committer c] returns the committer string. *)

  val message : t -> string
  (** [message c] returns the commit message. *)

  val timestamp : t -> int64
  (** [timestamp c] returns the commit timestamp (Unix epoch). *)

  (** {2 Construction} *)

  val v :
    tree:hash ->
    parents:hash list ->
    author:string ->
    ?committer:string ->
    ?timestamp:int64 ->
    message:string ->
    unit ->
    t
  (** [v ~tree ~parents ~author ?committer ?timestamp ~message ()] creates a new
      commit. *)

  (** {2 Serialization} *)

  val hash : t -> hash
  (** [hash c] computes the commit hash. *)

  val of_bytes : string -> (t, [> `Msg of string ]) result
  (** [of_bytes data] deserializes a commit. *)

  val to_bytes : t -> string
  (** [to_bytes c] serializes a commit. *)
end

(** {1 Pre-instantiated Commits} *)

module Git : module type of Make (Tree_format.Git)
(** Git-format commits with SHA-1 hashes. *)

module Mst : module type of Make (Tree_format.Mst)
(** MST-format commits with SHA-256 hashes. *)
