(** Subtree operations for monorepo management.

    This module provides first-class subtree operations that replace
    the need to shell out to [git subtree] commands. *)

(** {1 Subtree Functor} *)

module Make (F : Tree_format.S) : sig
  type hash = F.hash

  module Store : module type of Store.Make (F)

  (** {2 Subtree Split} *)

  val split : Store.t -> prefix:Store.Tree.path -> Store.t
  (** [split store ~prefix] extracts the subtree at [prefix] into a
      new store with rewritten history containing only commits that
      touch that prefix.

      Like [git subtree split --prefix]. *)

  (** {2 Subtree Add} *)

  val add : Store.t -> prefix:Store.Tree.path -> source:Store.t -> hash
  (** [add store ~prefix ~source] adds the contents of [source] as a
      subtree at [prefix], creating a merge commit.

      Like [git subtree add --prefix --squash]. *)

  (** {2 Subtree Pull} *)

  val pull :
    Store.t ->
    prefix:Store.Tree.path ->
    source:Store.t ->
    (hash, [> `Conflict of Store.Tree.path list ]) result
  (** [pull store ~prefix ~source] pulls updates from [source] into
      the subtree at [prefix].

      Like [git subtree pull --prefix --squash]. *)

  (** {2 Subtree Push} *)

  val push : Store.t -> prefix:Store.Tree.path -> target:Store.t -> hash
  (** [push store ~prefix ~target] pushes changes from the subtree at
      [prefix] to [target].

      Like [git subtree push --prefix]. *)

  (** {2 Status} *)

  type status =
    [ `In_sync
    | `Local_ahead of int
    | `Remote_ahead of int
    | `Diverged of int * int  (** local, remote *)
    | `Trees_differ ]

  val status :
    Store.t -> prefix:Store.Tree.path -> external_:Store.t -> status
  (** [status store ~prefix ~external_] compares the subtree at [prefix]
      with the external store.

      - [`In_sync]: Trees are identical
      - [`Local_ahead n]: Local has n commits not in external
      - [`Remote_ahead n]: External has n commits not in local
      - [`Diverged]: Both have independent commits
      - [`Trees_differ]: Trees differ but no history relationship *)
end

(** {1 Pre-instantiated Subtree} *)

module Git : module type of Make (Tree_format.Git)
(** Git-format subtree operations. *)
