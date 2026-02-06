(** Common CLI helpers. *)

open Irmin

(* Output helpers using Tty *)
let success fmt =
  let style = Tty.Style.(fg Tty.Color.green) in
  Fmt.pr ("%a " ^^ fmt ^^ "@.") (Tty.Style.styled style Fmt.string) "✓"

let error fmt =
  let style = Tty.Style.(fg Tty.Color.red) in
  Fmt.epr ("%a " ^^ fmt ^^ "@.") (Tty.Style.styled style Fmt.string) "✗"

let styled_bold = Tty.Style.(styled bold Fmt.string)
let styled_cyan = Tty.Style.(styled (fg Tty.Color.cyan) Fmt.string)
let styled_faint = Tty.Style.(styled faint Fmt.string)
let styled_yellow = Tty.Style.(styled (fg Tty.Color.yellow) Fmt.string)
let styled_blue = Tty.Style.(styled (fg Tty.Color.blue) Fmt.string)

let path_of_string s =
  String.split_on_char '/' s |> List.filter (fun s -> s <> "")

type log_entry = { hash : string; author : string; message : string }
(** Log entry for commit history. *)

(** Backend module signature - first-class modules for extensibility. *)
module type BACKEND = sig
  type store
  type tree
  type hash

  val open_store :
    sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> config:Config.t -> store

  val checkout : store -> branch:string -> tree option
  val empty_tree : store -> tree
  val tree_find : tree -> string list -> string option
  val tree_add : tree -> string list -> string -> tree
  val tree_remove : tree -> string list -> tree
  val tree_list : tree -> string list -> (string * [ `Contents | `Node ]) list
  val head : store -> branch:string -> hash option

  val commit :
    store ->
    tree:tree ->
    parents:hash list ->
    message:string ->
    author:string ->
    hash

  val set_head : store -> branch:string -> hash -> unit
  val branches : store -> string list
  val log : store -> branch:string -> limit:int option -> log_entry list
  val hash_to_hex : hash -> string
  val hash_short : hash -> string
end

(** Git backend implementation. *)
module Git : BACKEND = struct
  type store = Store.Git.t
  type tree = Tree.Git.t
  type hash = Hash.sha1

  let open_store ~sw ~fs ~config =
    let git_dir = Fpath.(v config.Config.store_path / ".git") in
    Git_interop.import_git ~sw ~fs ~git_dir

  let checkout store ~branch = Store.Git.checkout store ~branch
  let empty_tree _store = Tree.Git.empty ()
  let tree_find tree path = Tree.Git.find tree path
  let tree_add tree path content = Tree.Git.add tree path content
  let tree_remove tree path = Tree.Git.remove tree path
  let tree_list tree path = Tree.Git.list tree path
  let head store ~branch = Store.Git.head store ~branch

  let commit store ~tree ~parents ~message ~author =
    Store.Git.commit store ~tree ~parents ~message ~author

  let set_head store ~branch hash = Store.Git.set_head store ~branch hash
  let branches store = Store.Git.branches store

  let log store ~branch ~limit =
    let rec walk n hash acc =
      if n = Some 0 then List.rev acc
      else
        match Store.Git.read_commit store hash with
        | None -> List.rev acc
        | Some commit -> (
            let entry =
              {
                hash = Hash.to_hex hash;
                author = Commit.Git.author commit;
                message = Commit.Git.message commit;
              }
            in
            match Commit.Git.parents commit with
            | [] -> List.rev (entry :: acc)
            | p :: _ -> walk (Option.map pred n) p (entry :: acc))
    in
    match Store.Git.head store ~branch with
    | None -> []
    | Some h -> walk limit h []

  let hash_to_hex h = Hash.to_hex h
  let hash_short h = String.sub (Hash.to_hex h) 0 7
end

(** MST backend implementation using ATProto blockstore. *)
module Mst : BACKEND = struct
  type store = Atp.Blockstore.writable
  type tree = Atp.Mst.node * Atp.Blockstore.writable
  type hash = Atp.Cid.t

  let open_store ~sw:_ ~fs ~config =
    match config.Config.backend with
    | Config.Memory -> Atp.Blockstore.memory ()
    | Config.Mst | Config.Git ->
        let irmin_dir = Filename.concat config.Config.store_path ".irmin" in
        (try Unix.mkdir irmin_dir 0o755 with Unix.Unix_error _ -> ());
        let blocks_path = Eio.Path.(fs / irmin_dir / "blocks") in
        Atp.Blockstore.filesystem blocks_path

  let checkout _store ~branch =
    (* TODO: Load root from refs *)
    ignore branch;
    None

  let empty_tree store = (Atp.Mst.empty, store)

  let tree_find (mst, bs) path =
    let key = String.concat "/" path in
    match Atp.Mst.get key mst ~store:(bs :> Atp.Blockstore.readable) with
    | None -> None
    | Some cid -> bs#get cid

  let tree_add (mst, bs) path content =
    let key = String.concat "/" path in
    let cid = Atp.Cid.of_string content in
    bs#put cid content;
    let mst' = Atp.Mst.add key cid mst ~store:bs in
    (mst', bs)

  let tree_remove (mst, bs) path =
    let key = String.concat "/" path in
    let mst' = Atp.Mst.remove key mst ~store:bs in
    (mst', bs)

  let tree_list (mst, bs) path =
    let prefix =
      match path with [] -> "" | _ -> String.concat "/" path ^ "/"
    in
    Atp.Mst.leaves mst ~store:(bs :> Atp.Blockstore.readable)
    |> Seq.filter_map (fun (k, _cid) ->
        if
          prefix = ""
          || String.length k > String.length prefix
             && String.sub k 0 (String.length prefix) = prefix
        then
          let suffix =
            String.sub k (String.length prefix)
              (String.length k - String.length prefix)
          in
          match String.index_opt suffix '/' with
          | None -> Some (suffix, `Contents)
          | Some i -> Some (String.sub suffix 0 i, `Node)
        else None)
    |> List.of_seq |> List.sort_uniq compare

  let head _store ~branch =
    (* TODO: Store refs in blockstore *)
    ignore branch;
    None

  let commit bs ~tree:(mst, _) ~parents ~message ~author =
    ignore parents;
    ignore message;
    ignore author;
    let cid = Atp.Mst.to_cid mst ~store:bs in
    bs#sync;
    cid

  let set_head _store ~branch _hash =
    (* TODO: Store refs *)
    ignore branch

  let branches _store = [ "main" ]

  let log _store ~branch ~limit =
    (* MST stores don't have traditional commit history *)
    ignore branch;
    ignore limit;
    []

  let hash_to_hex cid = Atp.Cid.to_string cid

  let hash_short cid =
    let s = Atp.Cid.to_string cid in
    if String.length s > 7 then String.sub s 0 7 else s
end

(** Get the appropriate backend module for a configuration. *)
let backend_of_config (config : Config.t) : (module BACKEND) =
  match config.backend with
  | Config.Git -> (module Git)
  | Config.Mst | Config.Memory -> (module Mst)
