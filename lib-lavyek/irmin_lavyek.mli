(** Irmin backend using Lavyek as the underlying KV store.

    Lavyek is an LSM tree with WAL, SST compaction, and page caching. It
    provides high-throughput persistent storage suitable for production
    workloads. *)

val create_with_hash :
  ?use_fsync:bool ->
  sw:Eio.Switch.t ->
  Eio.Fs.dir_ty Eio.Path.t ->
  ('h -> string) ->
  (string -> ('h, [ `Msg of string ]) result) ->
  ('h -> 'h -> bool) ->
  'h Irmin.Backend.t
(** [create_with_hash ~sw root to_hex of_hex equal] creates a Lavyek-backed
    store at [root]. When [use_fsync] is [true], each write is fsynced to disk.
    Default: [true]. *)

val create_sha1 :
  ?cache:int ->
  ?use_fsync:bool ->
  sw:Eio.Switch.t -> Eio.Fs.dir_ty Eio.Path.t -> Irmin.Hash.sha1 Irmin.Backend.t
(** Create a Lavyek-backed SHA-1 store. If [cache] is given, wraps with an
    LRU cache of that capacity. When [use_fsync] is [false], writes are not
    fsynced (faster but less crash-safe). Default: [true]. *)

val create_sha256 :
  ?cache:int ->
  ?use_fsync:bool ->
  sw:Eio.Switch.t -> Eio.Fs.dir_ty Eio.Path.t -> Irmin.Hash.sha256 Irmin.Backend.t
(** Create a Lavyek-backed SHA-256 store. If [cache] is given, wraps with an
    LRU cache of that capacity. When [use_fsync] is [false], writes are not
    fsynced (faster but less crash-safe). Default: [true]. *)

val create :
  ?cache:int ->
  ?use_fsync:bool ->
  sw:Eio.Switch.t -> Eio.Fs.dir_ty Eio.Path.t -> Irmin.Hash.sha1 Irmin.Backend.t
(** Alias for {!create_sha1}. *)
