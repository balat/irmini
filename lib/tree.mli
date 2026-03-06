(** Lazy trees with delayed writes.

    Trees are like Git's staging area: immutable, temporary, non-persistent
    areas held in memory. Reads are done lazily and writes are accumulated until
    commit - if you modify a key twice, only the last change is written. *)

(** {1 Tree Functor} *)

module Make (F : Codec.S) : sig
  type t
  (** Immutable in-memory tree with lazy reads and delayed writes. *)

  type hash = F.hash

  (** {2 Path Type} *)

  type path = string list
  (** A path is a list of path segments. *)

  (** {2 Concrete Trees} *)

  type concrete = [ `Contents of string | `Tree of (string * concrete) list ]
  (** Fully materialized tree for import/export. *)

  (** {2 Construction} *)

  val empty : unit -> t
  (** [empty ()] creates an empty tree. *)

  val of_hash : backend:hash Backend.t -> hash -> t
  (** [of_hash ~backend h] creates a tree backed by the store. Nothing is loaded
      until accessed (lazy reads). *)

  val of_concrete : concrete -> t
  (** [of_concrete c] creates a tree from a fully materialized tree. *)

  val shallow : hash -> t
  (** [shallow h] creates a tree with only a hash reference. Accessing contents
      raises an error. *)

  val pruned : hash -> t
  (** [pruned h] creates a pruned tree that raises on dereference. Used for GC
      and export operations. *)

  (** {2 Reads (Lazy)} *)

  val find : t -> path -> string option
  (** [find t path] looks up contents at [path]. Loads nodes lazily as needed.
  *)

  val find_tree : t -> path -> t option
  (** [find_tree t path] looks up a subtree at [path]. *)

  val list : t -> path -> (string * [ `Node | `Contents ]) list
  (** [list t path] lists entries at [path]. *)

  val mem : t -> path -> bool
  (** [mem t path] checks if [path] exists. *)

  val mem_tree : t -> path -> bool
  (** [mem_tree t path] checks if a subtree exists at [path]. *)

  (** {2 Writes (Delayed)} *)

  val add : t -> path -> string -> t
  (** [add t path contents] adds contents at [path]. The write is accumulated,
      not performed immediately. *)

  val add_tree : t -> path -> t -> t
  (** [add_tree t path subtree] adds a subtree at [path]. *)

  val remove : t -> path -> t
  (** [remove t path] removes the entry at [path]. *)

  (** {2 Materialization} *)

  val to_concrete : t -> concrete
  (** [to_concrete t] fully materializes the tree. Forces all lazy nodes to be
      loaded. *)

  val hash : ?inline_threshold:int -> t -> backend:hash Backend.t -> hash
  (** [hash ?inline_threshold t ~backend] computes the tree hash. Writes all
      accumulated changes to the backend. If [inline_threshold] is given,
      contents at or below that size (in bytes) are stored directly in the
      parent node rather than as separate blobs. Defaults to the codec's
      [inline_threshold]. *)

  (** {2 Force Control} *)

  type 'a force = [ `True | `False of hash -> 'a | `Shallow of hash -> 'a ]
  (** Control how lazy nodes are handled during traversal:
      - [`True]: force loading of all nodes
      - [`False f]: call [f] on unloaded hashes instead
      - [`Shallow f]: like [`False] but for shallow trees *)

  val fold :
    ?force:'a force ->
    t ->
    'a ->
    (path -> [ `Contents of string | `Tree ] -> 'a -> 'a) ->
    'a
  (** [fold ~force t init f] traverses the tree. The [force] parameter controls
      lazy loading behavior. *)

  (** {2 Cache Management} *)

  val clear : ?depth:int -> t -> unit
  (** [clear ?depth t] purges cached data. If [depth] is given, only clears
      nodes at that depth or deeper. *)

  (** {2 Comparison} *)

  val equal : t -> t -> bool
  (** [equal t1 t2] compares trees structurally. *)
end

(** {1 Pre-instantiated Trees} *)

module Git : module type of Make (Codec.Git)
(** Git-format trees with SHA-1 hashes. *)

module Mst : module type of Make (Codec.Mst)
(** MST-format trees with SHA-256 hashes. *)
