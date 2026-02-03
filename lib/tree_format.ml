module type S = sig
  type node
  type hash

  val hash_node : node -> hash
  val hash_contents : string -> hash
  val node_of_bytes : string -> (node, [> `Msg of string ]) result
  val bytes_of_node : node -> string
  val empty_node : node
  val find : node -> string -> [ `Node of hash | `Contents of hash ] option
  val add : node -> string -> [ `Node of hash | `Contents of hash ] -> node
  val remove : node -> string -> node
  val list : node -> (string * [ `Node of hash | `Contents of hash ]) list
  val is_empty : node -> bool

  (* Hash operations *)
  val hash_to_bytes : hash -> string
  val hash_to_hex : hash -> string
  val hash_of_hex : string -> (hash, [> `Msg of string ]) result
  val hash_equal : hash -> hash -> bool
  val hash_compare : hash -> hash -> int

  (* Commit operations *)
  type commit

  val commit_make :
    tree:hash ->
    parents:hash list ->
    author:string ->
    committer:string ->
    message:string ->
    timestamp:int64 ->
    commit

  val commit_tree : commit -> hash
  val commit_parents : commit -> hash list
  val commit_author : commit -> string
  val commit_committer : commit -> string
  val commit_message : commit -> string
  val commit_timestamp : commit -> int64
  val commit_of_bytes : string -> (commit, [> `Msg of string ]) result
  val commit_to_bytes : commit -> string
  val commit_hash : commit -> hash
end

module type SHA1 = S with type hash = Hash.sha1
module type SHA256 = S with type hash = Hash.sha256

(** Git tree object format using ocaml-git. *)
module Git : SHA1 = struct
  type hash = Hash.sha1
  type node = Git.Tree.t

  (* Convert between irmin Hash.sha1 and Git.Hash.t *)
  let git_hash_of_sha1 (h : hash) : Git.Hash.t =
    Git.Hash.of_raw_string (Hash.to_bytes h)

  let sha1_of_git_hash (h : Git.Hash.t) : hash =
    Hash.sha1_of_bytes (Git.Hash.to_raw_string h)

  let empty_node = Git.Tree.empty
  let is_empty = Git.Tree.is_empty

  let find node name =
    match Git.Tree.find ~name node with
    | None -> None
    | Some entry -> (
        let h = sha1_of_git_hash entry.hash in
        match entry.perm with `Dir -> Some (`Node h) | _ -> Some (`Contents h))

  let add node name kind =
    let perm, hash =
      match kind with
      | `Node h -> (`Dir, git_hash_of_sha1 h)
      | `Contents h -> (`Normal, git_hash_of_sha1 h)
    in
    let entry = Git.Tree.entry ~perm ~name hash in
    Git.Tree.add entry node

  let remove node name = Git.Tree.remove ~name node

  let list node =
    Git.Tree.to_list node
    |> List.map (fun (entry : Git.Tree.entry) ->
        let h = sha1_of_git_hash entry.hash in
        let kind = match entry.perm with `Dir -> `Node h | _ -> `Contents h in
        (entry.name, kind))

  let bytes_of_node = Git.Tree.to_string

  let node_of_bytes s : (node, [> `Msg of string ]) result =
    match Git.Tree.of_string s with Ok n -> Ok n | Error (`Msg m) -> Error (`Msg m)

  let hash_node node = sha1_of_git_hash (Git.Tree.digest node)

  let hash_contents data =
    sha1_of_git_hash (Git.Hash.digest_string ~kind:`Blob data)

  let hash_to_bytes = Hash.to_bytes
  let hash_to_hex = Hash.to_hex

  let hash_of_hex s : (hash, [> `Msg of string ]) result =
    Hash.sha1_of_hex s

  let hash_equal = Hash.equal
  let hash_compare = Hash.compare

  (* Commit operations using ocaml-git *)
  type commit = Git.Commit.t

  let commit_make ~tree ~parents ~author ~committer ~message ~timestamp =
    let user_of_string s =
      (* Parse "Name <email>" format, or use as-is *)
      Git.User.make ~name:s ~email:"" ~date:timestamp ()
    in
    Git.Commit.make ~tree:(git_hash_of_sha1 tree)
      ~parents:(List.map git_hash_of_sha1 parents)
      ~author:(user_of_string author)
      ~committer:(user_of_string committer)
      (Some message)

  let commit_tree c = sha1_of_git_hash (Git.Commit.tree c)
  let commit_parents c = List.map sha1_of_git_hash (Git.Commit.parents c)
  let commit_author c = Git.User.name (Git.Commit.author c)
  let commit_committer c = Git.User.name (Git.Commit.committer c)
  let commit_message c = Option.value ~default:"" (Git.Commit.message c)
  let commit_timestamp c = Git.User.date (Git.Commit.author c)

  let commit_of_bytes s : (commit, [> `Msg of string ]) result =
    match Git.Commit.of_string s with
    | Ok c -> Ok c
    | Error (`Msg m) -> Error (`Msg m)

  let commit_to_bytes = Git.Commit.to_string
  let commit_hash c = sha1_of_git_hash (Git.Commit.digest c)
end

(** ATProto Merkle Search Tree format using ocaml-atp.

    MST uses SHA-256 with 2-bit prefix counting for tree depth. Keys are stored
    sorted with common prefix compression. Encoded as DAG-CBOR. *)
module Mst : SHA256 = struct
  type hash = Hash.sha256

  (* Convert between irmin Hash.sha256 and Atp.Cid.t *)
  let cid_of_sha256 (h : hash) : Atp.Cid.t =
    Atp.Cid.of_digest `Dag_cbor (Hash.to_bytes h)

  let sha256_of_cid (cid : Atp.Cid.t) : hash =
    Hash.sha256_of_bytes (Atp.Cid.digest cid)

  (* Our node wraps Atp.Mst.Raw.node for serialization *)
  type node = Atp.Mst.Raw.node

  let empty_node : node = { l = None; e = [] }
  let is_empty (node : node) = node.l = None && node.e = []

  (* Decompress key from entry list *)
  let decompress_keys (entries : Atp.Mst.Raw.entry list) :
      (string * Atp.Mst.Raw.entry) list =
    let rec loop prev_key acc = function
      | [] -> List.rev acc
      | (e : Atp.Mst.Raw.entry) :: rest ->
          let key = String.sub prev_key 0 e.p ^ e.k in
          loop key ((key, e) :: acc) rest
    in
    loop "" [] entries

  let find (node : node) name =
    let entries = decompress_keys node.e in
    match List.find_opt (fun (k, _) -> k = name) entries with
    | None -> None
    | Some (_, e) ->
        (* In MST, all values are content CIDs, subtrees are in 't' field *)
        Some (`Contents (sha256_of_cid e.v))

  (* Compress keys for serialization *)
  let compress_keys entries =
    let sorted =
      List.sort (fun (k1, _) (k2, _) -> String.compare k1 k2) entries
    in
    let rec loop prev_key acc = function
      | [] -> List.rev acc
      | (key, (v, t)) :: rest ->
          let p =
            let rec shared i =
              if i >= String.length prev_key || i >= String.length key then i
              else if prev_key.[i] = key.[i] then shared (i + 1)
              else i
            in
            shared 0
          in
          let k = String.sub key p (String.length key - p) in
          let entry : Atp.Mst.Raw.entry = { p; k; v; t } in
          loop key (entry :: acc) rest
    in
    loop "" [] sorted

  let add (node : node) name kind =
    let entries = decompress_keys node.e in
    let v, t =
      match kind with
      | `Contents h -> (cid_of_sha256 h, None)
      | `Node h -> (cid_of_sha256 h, None)
      (* TODO: Handle subtree pointers *)
    in
    let _ = t in (* suppress unused warning *)
    let entries = List.filter (fun (k, _) -> k <> name) entries in
    let entries =
      (name, (v, None))
      :: List.map
           (fun (k, (e : Atp.Mst.Raw.entry)) -> (k, (e.v, e.t)))
           entries
    in
    let compressed = compress_keys entries in
    { node with e = compressed }

  let remove (node : node) name =
    let entries = decompress_keys node.e in
    let entries = List.filter (fun (k, _) -> k <> name) entries in
    let entries =
      List.map (fun (k, (e : Atp.Mst.Raw.entry)) -> (k, (e.v, e.t))) entries
    in
    let compressed = compress_keys entries in
    { node with e = compressed }

  let list (node : node) =
    let entries = decompress_keys node.e in
    List.map
      (fun (key, (e : Atp.Mst.Raw.entry)) -> (key, `Contents (sha256_of_cid e.v)))
      entries

  let bytes_of_node node = Atp.Mst.Raw.encode_bytes node

  let node_of_bytes data : (node, [> `Msg of string ]) result =
    try Ok (Atp.Mst.Raw.decode_bytes data)
    with _ -> Error (`Msg "failed to decode MST node")

  let hash_node node =
    let data = bytes_of_node node in
    Hash.sha256 data

  let hash_contents data = Hash.sha256 data

  let hash_to_bytes = Hash.to_bytes
  let hash_to_hex = Hash.to_hex

  let hash_of_hex s : (hash, [> `Msg of string ]) result =
    Hash.sha256_of_hex s

  let hash_equal = Hash.equal
  let hash_compare = Hash.compare

  (* Commit operations for MST format using DAG-CBOR *)
  type commit = {
    tree : hash;
    parents : hash list;
    author : string;
    committer : string;
    message : string;
    timestamp : int64;
  }

  let commit_make ~tree ~parents ~author ~committer ~message ~timestamp =
    { tree; parents; author; committer; message; timestamp }

  let commit_tree c = c.tree
  let commit_parents c = c.parents
  let commit_author c = c.author
  let commit_committer c = c.committer
  let commit_message c = c.message
  let commit_timestamp c = c.timestamp

  let commit_of_bytes s : (commit, [> `Msg of string ]) result =
    try
      let v = Atp.Dagcbor.decode_string ~cid_format:`Atproto s in
      match v with
      | `Map fields ->
          let get_string key =
            match List.assoc_opt key fields with
            | Some (`String s) -> s
            | _ -> ""
          in
          let get_int64 key =
            match List.assoc_opt key fields with
            | Some (`Int i) -> i
            | _ -> 0L
          in
          let get_link key =
            match List.assoc_opt key fields with
            | Some (`Link cid) -> sha256_of_cid cid
            | _ -> Hash.sha256 ""
          in
          let get_links key =
            match List.assoc_opt key fields with
            | Some (`List links) ->
                List.filter_map
                  (function `Link cid -> Some (sha256_of_cid cid) | _ -> None)
                  links
            | _ -> []
          in
          Ok
            {
              tree = get_link "tree";
              parents = get_links "parents";
              author = get_string "author";
              committer = get_string "committer";
              message = get_string "message";
              timestamp = get_int64 "timestamp";
            }
      | _ -> Error (`Msg "expected map for commit")
    with Eio.Io _ as e -> Error (`Msg (Printexc.to_string e))

  let commit_to_bytes c =
    let v : Atp.Dagcbor.value =
      `Map
        [
          ("author", `String c.author);
          ("committer", `String c.committer);
          ("message", `String c.message);
          ("parents", `List (List.map (fun h -> `Link (cid_of_sha256 h)) c.parents));
          ("timestamp", `Int c.timestamp);
          ("tree", `Link (cid_of_sha256 c.tree));
        ]
    in
    Atp.Dagcbor.encode_string ~cid_format:`Atproto v

  let commit_hash c =
    let data = commit_to_bytes c in
    Hash.sha256 data
end
