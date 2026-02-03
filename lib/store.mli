(** High-level store interface.

    Combines backend, tree, and commit operations into a unified API. *)

(** {1 Store Functor} *)

module Make (F : Tree_format.S) : sig
  type t
  (** A store instance. *)

  type hash = F.hash

  module Tree : module type of Tree.Make (F)
  module Commit : module type of Commit.Make (F)

  (** {2 Construction} *)

  val create : backend:hash Backend.t -> t
  (** [create ~backend] creates a store backed by [backend]. *)

  (** {2 Tree Operations} *)

  val tree : t -> ?at:hash -> unit -> Tree.t
  (** [tree t ?at ()] returns a tree.
      If [at] is given, returns the tree at that commit.
      Otherwise returns an empty tree. *)

  val checkout : t -> branch:string -> Tree.t option
  (** [checkout t ~branch] returns the tree at the head of [branch]. *)

  (** {2 Commit Operations} *)

  val commit :
    t ->
    tree:Tree.t ->
    parents:hash list ->
    message:string ->
    author:string ->
    hash
  (** [commit t ~tree ~parents ~message ~author] creates a commit.
      This is when delayed tree writes actually happen. *)

  (** {2 Branch Operations} *)

  val head : t -> branch:string -> hash option
  (** [head t ~branch] returns the head commit of [branch]. *)

  val set_head : t -> branch:string -> hash -> unit
  (** [set_head t ~branch h] sets the head of [branch] to [h]. *)

  val branches : t -> string list
  (** [branches t] returns all branch names. *)

  val update_branch : t -> branch:string -> old:hash option -> new_:hash -> bool
  (** [update_branch t ~branch ~old ~new_] atomically updates [branch]
      if its current head matches [old]. *)

  (** {2 Ancestry Queries} *)

  val is_ancestor : t -> ancestor:hash -> descendant:hash -> bool
  (** [is_ancestor t ~ancestor ~descendant] checks commit ancestry. *)

  val merge_base : t -> hash -> hash -> hash option
  (** [merge_base t h1 h2] finds the common ancestor of two commits. *)

  val commits_between : t -> base:hash -> head:hash -> int
  (** [commits_between t ~base ~head] counts commits from [base] to [head]. *)

  (** {2 Diff} *)

  type diff_entry =
    [ `Add of Tree.path * hash
    | `Remove of Tree.path
    | `Change of Tree.path * hash * hash ]

  val diff : t -> old:hash -> new_:hash -> diff_entry Seq.t
  (** [diff t ~old ~new_] computes the difference between two trees. *)

  (** {2 Low-level} *)

  val backend : t -> hash Backend.t
  (** [backend t] returns the underlying backend. *)

  val read_commit : t -> hash -> Commit.t option
  (** [read_commit t h] reads a commit by hash. *)

  val read_tree : t -> hash -> Tree.t
  (** [read_tree t h] returns a lazy tree at [h]. *)
end

(** {1 Pre-instantiated Stores} *)

module Git : module type of Make (Tree_format.Git)
(** Git-format store with SHA-1 hashes. *)

module Mst : module type of Make (Tree_format.Mst)
(** MST-format store with SHA-256 hashes. *)
