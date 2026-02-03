(** Merkle proofs for content-addressed trees.

    Proofs are sparse trees where unvisited paths are replaced by their hash
    ("blinded"). They allow verification of computations without full tree
    access.

    {[
      (* Producer has full tree access *)
      let proof, result = Proof.produce store tree (fun t ->
        let v = Tree.find t ["foo"; "bar"] in
        (t, v))

      (* Verifier only needs the proof *)
      match Proof.verify proof (fun t ->
        let v = Tree.find t ["foo"; "bar"] in
        (t, v)) with
      | Ok (_, v) -> (* v is trusted *)
      | Error `Proof_mismatch -> (* invalid proof *)
    ]}

    Compatible with ATProto's MST proof format when using the MST codec. *)

(** {1 Proof Trees} *)

type 'hash kinded_hash = [ `Contents of 'hash | `Node of 'hash ]
(** Hash tagged with its kind. *)

(** Sparse tree with blinded (hash-only) subtrees. *)
type ('hash, 'contents) tree =
  | Contents of 'contents
  | Blinded_contents of 'hash
  | Node of ('hash, 'contents) node
  | Blinded_node of 'hash

and ('hash, 'contents) node = (string * ('hash, 'contents) tree) list
(** Node entries, sorted by key. *)

(** {1 Proofs} *)

type ('hash, 'contents) t
(** A Merkle proof with before/after state hashes. *)

val v :
  before:'hash kinded_hash ->
  after:'hash kinded_hash ->
  ('hash, 'contents) tree ->
  ('hash, 'contents) t
(** [v ~before ~after tree] creates a proof that state changed from [before] to
    [after], with [tree] containing the minimal data needed to verify. *)

val before : ('hash, _) t -> 'hash kinded_hash
(** [before p] is the root hash before the computation. *)

val after : ('hash, _) t -> 'hash kinded_hash
(** [after p] is the root hash after the computation. *)

val state : ('hash, 'contents) t -> ('hash, 'contents) tree
(** [state p] is the sparse tree proving the computation. *)

(** {1 Producing and Verifying Proofs}

    These operations are parameterized by a codec for hashing. *)

module Make (C : Codec.S) : sig
  type hash = C.hash
  type contents = string

  module Tree : sig
    type t
    (** Proof-aware tree that records accesses during [produce]. *)

    val find : t -> string list -> contents option
    val find_tree : t -> string list -> t option
    val mem : t -> string list -> bool
    val list : t -> string list -> (string * [ `Node | `Contents ]) list
    val add : t -> string list -> contents -> t
    val add_tree : t -> string list -> t -> t
    val remove : t -> string list -> t
    val hash : t -> hash
  end

  val produce :
    hash Backend.t -> hash -> (Tree.t -> Tree.t * 'a) -> (hash, contents) t * 'a
  (** [produce backend root_hash f] runs [f] on the tree at [root_hash],
      recording all accesses. Returns a proof containing only accessed paths. *)

  val verify :
    (hash, contents) t ->
    (Tree.t -> Tree.t * 'a) ->
    (Tree.t * 'a, [ `Proof_mismatch of string ]) result
  (** [verify proof f] replays [f] on the proof tree. Returns [Ok] if the result
      tree's hash matches [after proof], [Error] otherwise. *)

  val to_tree : (hash, contents) t -> Tree.t
  (** [to_tree proof] converts a proof to a tree for inspection. *)

  val hash_of_tree : (hash, contents) tree -> hash kinded_hash
  (** [hash_of_tree t] computes the root hash of a proof tree. *)
end

module Git : module type of Make (Codec.Git)
module Mst : module type of Make (Codec.Mst)
