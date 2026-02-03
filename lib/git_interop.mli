(** Git interoperability.

    Bidirectional support for reading and writing Git repositories.
    This allows Irmin to work with existing .git directories and
    interoperate with the Git ecosystem. *)

(** {1 Git Repository Operations} *)

val import_git :
  sw:Eio.Switch.t ->
  fs:_ Eio.Path.t ->
  git_dir:string ->
  Store.Git.t
(** [import_git ~sw ~fs ~git_dir] opens a .git directory as an Irmin store.
    The store supports both reads and writes - changes are written back
    in Git-compatible format. *)

val init_git :
  sw:Eio.Switch.t ->
  fs:_ Eio.Path.t ->
  path:string ->
  Store.Git.t
(** [init_git ~sw ~fs ~path] initializes a new Git repository at [path]
    and returns an Irmin store for it. *)

(** {1 Object Operations} *)

val read_object :
  sw:Eio.Switch.t ->
  fs:_ Eio.Path.t ->
  git_dir:string ->
  Hash.sha1 ->
  (string * string, [> `Msg of string ]) result
(** [read_object ~sw ~fs ~git_dir hash] reads a Git object, returning
    [(type, data)] where type is "blob", "tree", "commit", or "tag". *)

val write_object :
  sw:Eio.Switch.t ->
  fs:_ Eio.Path.t ->
  git_dir:string ->
  typ:string ->
  string ->
  Hash.sha1
(** [write_object ~sw ~fs ~git_dir ~typ data] writes a Git object. *)

(** {1 Reference Operations} *)

val read_ref :
  sw:Eio.Switch.t ->
  fs:_ Eio.Path.t ->
  git_dir:string ->
  string ->
  Hash.sha1 option
(** [read_ref ~sw ~fs ~git_dir name] reads a Git reference. *)

val write_ref :
  sw:Eio.Switch.t ->
  fs:_ Eio.Path.t ->
  git_dir:string ->
  string ->
  Hash.sha1 ->
  unit
(** [write_ref ~sw ~fs ~git_dir name hash] writes a Git reference. *)

val list_refs :
  sw:Eio.Switch.t ->
  fs:_ Eio.Path.t ->
  git_dir:string ->
  string list
(** [list_refs ~sw ~fs ~git_dir] lists all references. *)

(** {1 Pack File Operations} *)

val read_pack_index :
  sw:Eio.Switch.t ->
  fs:_ Eio.Path.t ->
  path:string ->
  (Hash.sha1 * int64) list
(** [read_pack_index ~sw ~fs ~path] reads a .idx file, returning
    [(hash, offset)] pairs. *)

val read_from_pack :
  sw:Eio.Switch.t ->
  fs:_ Eio.Path.t ->
  pack:string ->
  offset:int64 ->
  (string * string, [> `Msg of string ]) result
(** [read_from_pack ~sw ~fs ~pack ~offset] reads an object from a pack file
    at the given offset. *)
