(** Irmin 4.0 - Content-addressable storage for OCaml.

    Irmin provides two APIs:
    - {b Link API}: Minimal interface for persisting OCaml values.
    - {b Tree API}: Git-compatible version control with paths, commits, and
      branches.

    Both share a common content-addressable backend.

    Architecture: Link → Tree → KV

    {[
      Link ('a link)  →  Tree (lazy/staged)  →  KV/Backend (storage)
    ]}

    - {b Link}: Persistent pointers to OCaml values (['a link], [link], [fetch])
    - {b Tree}: Lazy reads, delayed writes (like Git's staging area)
    - {b KV}: Raw content-addressed storage by hash

    The Link API provides a simple way to persist arbitrary OCaml values:

    {[
      type tree = node Link.t
      and node = Empty | Node of { l : tree; v : int; r : tree }

      let leaf x =
        Link.link (Node { l = Link.link Empty; v = x; r = Link.link Empty })
    ]} *)

(** {1 Link Layer (Persistent Pointers)}

    The core abstraction: content-addressed pointers to OCaml values. *)

module Link = Link
(** Persistent pointers with [link] and [fetch]. *)

(** {1 KV Layer (Storage)}

    Content-addressed storage with refs for mutable pointers. *)

module Hash = Hash
(** Phantom-typed hashes (SHA-1, SHA-256). *)

module Backend = Backend
(** KV backend implementations (Memory, Git, layered, cached). *)

(** {1 Tree Layer (Staging)}

    Lazy reads, delayed writes. Like Git's index/staging area. Trees are built
    on top of links for Merkle tree structures. *)

module Codec = Codec
(** Format signatures and implementations (Git, MST, extensible). *)

module Tree = Tree
(** Lazy tree with delayed writes. *)

module Commit = Commit
(** Commit operations. *)

(** {1 High-Level API} *)

module Store = Store
(** Store combining trees, commits, and branches. *)

module Subtree = Subtree
(** Monorepo subtree operations. *)

module Proof = Proof
(** Merkle proofs for verified computations. *)

(** {1 Git Interoperability} *)

module Git_interop = Git_interop
(** Git repository I/O. *)

(** {1 Pre-instantiated: Git Format} *)

module Git = struct
  (** Git-compatible store (SHA-1, Git object format). *)

  module Tree = Tree.Git
  module Store = Store.Git
  module Subtree = Subtree.Git
  module Proof = Proof.Git

  let import = Git_interop.import_git
  let init = Git_interop.init_git
end

(** {1 Pre-instantiated: MST Format} *)

module Mst = struct
  (** ATProto-compatible store (SHA-256, DAG-CBOR MST). *)

  module Tree = Tree.Mst
  module Store = Store.Mst
  module Subtree = Subtree.Mst
  module Proof = Proof.Mst
end
