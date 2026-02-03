(** Irmin - Content-addressable store with Git and ATProto MST support.

    Irmin provides lazy reads, delayed writes, and multiple tree formats
    with bidirectional Git compatibility and first-class subtree operations. *)

(** {1 Core Types} *)

module Hash = Hash
module Backend = Backend

(** {1 Tree Formats} *)

module Tree_format = Tree_format

(** {1 Trees and Commits} *)

module Tree = Tree
module Commit = Commit

(** {1 Stores} *)

module Store = Store

(** {1 Subtree Operations} *)

module Subtree = Subtree

(** {1 Git Interoperability} *)

module Git_interop = Git_interop

(** {1 Pre-instantiated Git Store} *)

module Git = struct
  include Store.Git

  let import = Git_interop.import_git
  let init = Git_interop.init_git
end

(** {1 Pre-instantiated MST Store} *)

module Mst = Store.Mst
