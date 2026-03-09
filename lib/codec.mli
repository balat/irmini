(** Tree format abstraction - the ONE functor in Irmin.

    This module type defines how tree nodes are encoded and decoded. Different
    formats (Git trees, ATProto MST) implement this interface. This is the only
    functor-based abstraction point in the library. *)

(** {1 Module Type} *)

module type S = sig
  (** The tree format signature. *)

  type node
  (** The internal node representation. *)

  type hash
  (** The hash type used by this format. *)

  type entry =
    [ `Node of hash | `Contents of hash | `Contents_inlined of string ]
  (** A node entry: subtree hash, content hash, or inlined content. *)

  val inline_threshold : int
  (** Maximum serialized size (in bytes) for inlined contents. Contents at or
      below this size are stored directly in the node rather than as a separate
      blob. Set to 0 to disable inlining. *)

  val hash_node : node -> hash
  (** [hash_node n] computes the hash of [n]. *)

  val hash_contents : string -> hash
  (** [hash_contents data] computes the hash of content [data]. *)

  val node_of_bytes : string -> (node, [> `Msg of string ]) result
  (** [node_of_bytes data] deserializes a node from bytes. *)

  val bytes_of_node : node -> string
  (** [bytes_of_node n] serializes a node to bytes. *)

  val empty_node : node
  (** The empty node with no entries. *)

  val find : node -> string -> entry option
  (** [find node name] looks up an entry by name. *)

  val add : node -> string -> entry -> node
  (** [add node name entry] adds or replaces an entry. *)

  val remove : node -> string -> node
  (** [remove node name] removes an entry. *)

  val list : node -> (string * entry) list
  (** [list node] returns all entries sorted by name. *)

  val is_empty : node -> bool
  (** [is_empty node] returns true if the node has no entries. *)

  (** {2 Hash Operations} *)

  val hash_to_bytes : hash -> string
  (** [hash_to_bytes h] returns the raw bytes of [h]. *)

  val hash_to_hex : hash -> string
  (** [hash_to_hex h] returns the hexadecimal representation of [h]. *)

  val hash_of_hex : string -> (hash, [> `Msg of string ]) result
  (** [hash_of_hex s] parses a hexadecimal hash string. *)

  val hash_of_raw_bytes : string -> hash
  (** [hash_of_raw_bytes s] creates a hash from raw digest bytes. Raises
      [Invalid_argument] if [s] has the wrong length. *)

  val hash_equal : hash -> hash -> bool
  (** [hash_equal h1 h2] tests hash equality. *)

  val hash_compare : hash -> hash -> int
  (** [hash_compare h1 h2] compares hashes. *)

  (** {2 Commit Operations} *)

  type commit
  (** The commit representation. *)

  val commit_make :
    tree:hash ->
    parents:hash list ->
    author:string ->
    committer:string ->
    message:string ->
    timestamp:int64 ->
    commit
  (** Create a commit. *)

  val commit_tree : commit -> hash
  (** Tree hash of the commit. *)

  val commit_parents : commit -> hash list
  (** Parent commit hashes. *)

  val commit_author : commit -> string
  (** Author name. *)

  val commit_committer : commit -> string
  (** Committer name. *)

  val commit_message : commit -> string
  (** Commit message. *)

  val commit_timestamp : commit -> int64
  (** Commit timestamp. *)

  val commit_of_bytes : string -> (commit, [> `Msg of string ]) result
  (** Parse a commit from bytes. *)

  val commit_to_bytes : commit -> string
  (** Serialize a commit to bytes. *)

  val commit_hash : commit -> hash
  (** Compute the hash of a commit. *)
end

(** {1 Hash-Specific Signatures} *)

module type SHA1 = S with type hash = Hash.sha1
(** Tree format using SHA-1 (Git compatible). *)

module type SHA256 = S with type hash = Hash.sha256
(** Tree format using SHA-256 (ATProto compatible). *)

(** {1 Built-in Formats} *)

module Git : SHA1
(** Git tree object format. Bidirectional compatibility with Git. *)

module Mst : SHA256
(** ATProto Merkle Search Tree format. *)
