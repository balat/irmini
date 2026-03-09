(** Git interoperability.

    Bidirectional support for reading and writing Git repositories. This allows
    Irmin to work with existing .git directories and interoperate with the Git
    ecosystem. Pack files are handled transparently. *)

(** {1 Git Repository Operations} *)

val import_git :
  sw:Eio.Switch.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  git_dir:Fpath.t ->
  Store.Git.t
(** [import_git ~sw ~fs ~git_dir] opens a bare .git directory as an Irmin store.
    Supports both loose objects and pack files. *)

val open_git :
  sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> path:Fpath.t -> Store.Git.t
(** [open_git ~sw ~fs ~path] opens a Git repository (with .git subdirectory) as
    an Irmin store. Supports both loose objects and pack files. *)

val init_git :
  sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> path:Fpath.t -> Store.Git.t
(** [init_git ~sw ~fs ~path] initializes a new Git repository at [path] and
    returns an Irmin store for it. *)

(** {1 Backend} *)

val git_backend : Git.Repository.t -> Hash.sha1 Backend.t
(** [git_backend repo] creates a content-addressable backend that stores
    objects as Git objects in [repo]. *)

(** {1 Object Operations} *)

val read_object :
  sw:Eio.Switch.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  git_dir:Fpath.t ->
  Hash.sha1 ->
  (string * string, [> `Msg of string ]) result
(** [read_object ~sw ~fs ~git_dir hash] reads a Git object, returning
    [(type, data)] where type is "blob", "tree", "commit", or "tag". Checks
    loose objects first, then pack files. *)

val write_object :
  sw:Eio.Switch.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  git_dir:Fpath.t ->
  typ:string ->
  string ->
  Hash.sha1
(** [write_object ~sw ~fs ~git_dir ~typ data] writes a Git object as a
    zlib-compressed loose object. *)

(** {1 Reference Operations} *)

val read_ref :
  sw:Eio.Switch.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  git_dir:Fpath.t ->
  string ->
  Hash.sha1 option
(** [read_ref ~sw ~fs ~git_dir name] reads a Git reference. Follows symbolic
    refs. *)

val write_ref :
  sw:Eio.Switch.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  git_dir:Fpath.t ->
  string ->
  Hash.sha1 ->
  unit
(** [write_ref ~sw ~fs ~git_dir name hash] writes a Git reference. *)

val list_refs :
  sw:Eio.Switch.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  git_dir:Fpath.t ->
  string list
(** [list_refs ~sw ~fs ~git_dir] lists all references. *)
