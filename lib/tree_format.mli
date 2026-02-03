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

  val find : node -> string -> [ `Node of hash | `Contents of hash ] option
  (** [find node name] looks up an entry by name. *)

  val add : node -> string -> [ `Node of hash | `Contents of hash ] -> node
  (** [add node name entry] adds or replaces an entry. *)

  val remove : node -> string -> node
  (** [remove node name] removes an entry. *)

  val list : node -> (string * [ `Node of hash | `Contents of hash ]) list
  (** [list node] returns all entries sorted by name. *)

  val is_empty : node -> bool
  (** [is_empty node] returns true if the node has no entries. *)
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
