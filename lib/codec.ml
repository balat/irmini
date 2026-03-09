module type S = sig
  type node
  type hash

  type entry =
    [ `Node of hash | `Contents of hash | `Contents_inlined of string ]

  val inline_threshold : int
  val hash_node : node -> hash
  val hash_contents : string -> hash
  val node_of_bytes : string -> (node, [> `Msg of string ]) result
  val bytes_of_node : node -> string
  val empty_node : node
  val find : node -> string -> entry option
  val add : node -> string -> entry -> node
  val remove : node -> string -> node
  val list : node -> (string * entry) list
  val is_empty : node -> bool

  (* Hash operations *)
  val hash_to_bytes : hash -> string
  val hash_to_hex : hash -> string
  val hash_of_hex : string -> (hash, [> `Msg of string ]) result
  val hash_of_raw_bytes : string -> hash
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

  type entry =
    [ `Node of hash | `Contents of hash | `Contents_inlined of string ]

  (* Node wraps a Git tree plus a map of inlined small contents *)
  type node = {
    tree : Git.Tree.t;
    inlined : (string * string) list; (* name -> inlined content *)
  }

  (* Inline contents up to 48 bytes directly in tree nodes, avoiding a
     separate content-addressable store lookup. This breaks Git interop
     for inlined entries but improves performance on small values. *)
  let inline_threshold = 48

  (* Convert between irmin Hash.sha1 and Git.Hash.t *)
  let git_hash_of_sha1 (h : hash) : Git.Hash.t =
    Git.Hash.of_raw_string (Hash.to_bytes h)

  let sha1_of_git_hash (h : Git.Hash.t) : hash =
    Hash.sha1_of_bytes (Git.Hash.to_raw_string h)

  let empty_node = { tree = Git.Tree.empty; inlined = [] }
  let is_empty node = Git.Tree.is_empty node.tree && node.inlined = []

  let find node name =
    match List.assoc_opt name node.inlined with
    | Some data -> Some (`Contents_inlined data)
    | None -> (
        match Git.Tree.find ~name node.tree with
        | None -> None
        | Some entry -> (
            let h = sha1_of_git_hash entry.hash in
            match entry.perm with
            | `Dir -> Some (`Node h)
            | _ -> Some (`Contents h)))

  let add node name kind =
    match kind with
    | `Contents_inlined data ->
        let tree = Git.Tree.remove ~name node.tree in
        let inlined =
          (name, data) :: List.filter (fun (n, _) -> n <> name) node.inlined
        in
        { tree; inlined }
    | `Node h ->
        let inlined = List.filter (fun (n, _) -> n <> name) node.inlined in
        let tree = Git.Tree.remove ~name node.tree in
        let entry = Git.Tree.entry ~perm:`Dir ~name (git_hash_of_sha1 h) in
        { tree = Git.Tree.add entry tree; inlined }
    | `Contents h ->
        let inlined = List.filter (fun (n, _) -> n <> name) node.inlined in
        let tree = Git.Tree.remove ~name node.tree in
        let entry =
          Git.Tree.entry ~perm:`Normal ~name (git_hash_of_sha1 h)
        in
        { tree = Git.Tree.add entry tree; inlined }

  let remove node name =
    let inlined = List.filter (fun (n, _) -> n <> name) node.inlined in
    { tree = Git.Tree.remove ~name node.tree; inlined }

  let list node =
    let tree_entries =
      Git.Tree.to_list node.tree
      |> List.map (fun (entry : Git.Tree.entry) ->
          let h = sha1_of_git_hash entry.hash in
          let kind =
            match entry.perm with `Dir -> `Node h | _ -> `Contents h
          in
          (entry.name, kind))
    in
    let inlined_entries =
      List.map
        (fun (name, data) -> (name, `Contents_inlined data))
        node.inlined
    in
    List.sort
      (fun (a, _) (b, _) -> String.compare a b)
      (tree_entries @ inlined_entries)

  (* Serialization format:
     - Version 0 (backward compat): raw Git tree bytes (starts with ASCII digit)
     - Version 1: \x01 + 4-byte Git tree length + Git tree bytes + inlined entries
       Each inlined entry: 2-byte name length + name + 4-byte data length + data
     Standard Git trees always start with a mode digit (0-9), never \x01. *)

  let bytes_of_node node =
    let tree_bytes = Git.Tree.to_string node.tree in
    if node.inlined = [] then tree_bytes
    else
      let buf = Buffer.create (String.length tree_bytes + 64) in
      Buffer.add_char buf '\x01';
      Buffer.add_int32_be buf (Int32.of_int (String.length tree_bytes));
      Buffer.add_string buf tree_bytes;
      let sorted =
        List.sort (fun (a, _) (b, _) -> String.compare a b) node.inlined
      in
      List.iter
        (fun (name, data) ->
          let nlen = String.length name in
          let dlen = String.length data in
          Buffer.add_uint16_be buf nlen;
          Buffer.add_string buf name;
          Buffer.add_int32_be buf (Int32.of_int dlen);
          Buffer.add_string buf data)
        sorted;
      Buffer.contents buf

  let parse_inlined_entries s offset =
    let len = String.length s in
    let rec loop pos acc =
      if pos >= len then List.rev acc
      else
        let nlen = Char.code s.[pos] lsl 8 lor Char.code s.[pos + 1] in
        let name = String.sub s (pos + 2) nlen in
        let dpos = pos + 2 + nlen in
        let dlen =
          Char.code s.[dpos] lsl 24
          lor (Char.code s.[dpos + 1] lsl 16)
          lor (Char.code s.[dpos + 2] lsl 8)
          lor Char.code s.[dpos + 3]
        in
        let data = String.sub s (dpos + 4) dlen in
        loop (dpos + 4 + dlen) ((name, data) :: acc)
    in
    loop offset []

  let node_of_bytes s : (node, [> `Msg of string ]) result =
    if String.length s = 0 then Ok { tree = Git.Tree.empty; inlined = [] }
    else if Char.code s.[0] = 0x01 then begin
      (* Version 1: has inlined entries *)
      let tree_len =
        Char.code s.[1] lsl 24
        lor (Char.code s.[2] lsl 16)
        lor (Char.code s.[3] lsl 8)
        lor Char.code s.[4]
      in
      let tree_bytes = String.sub s 5 tree_len in
      let inlined_start = 5 + tree_len in
      let inlined = parse_inlined_entries s inlined_start in
      match Git.Tree.of_string tree_bytes with
      | Ok tree -> Ok { tree; inlined }
      | Error (`Msg m) -> Error (`Msg m)
    end
    else
      (* Version 0: standard Git tree, no inlined entries *)
      match Git.Tree.of_string s with
      | Ok tree -> Ok { tree; inlined = [] }
      | Error (`Msg m) -> Error (`Msg m)

  let hash_node node =
    let data = bytes_of_node node in
    sha1_of_git_hash (Git.Hash.digest_string ~kind:`Tree data)

  let hash_contents data =
    sha1_of_git_hash (Git.Hash.digest_string ~kind:`Blob data)

  let hash_to_bytes = Hash.to_bytes
  let hash_to_hex = Hash.to_hex
  let hash_of_hex s : (hash, [> `Msg of string ]) result = Hash.sha1_of_hex s
  let hash_of_raw_bytes = Hash.sha1_of_bytes
  let hash_equal = Hash.equal
  let hash_compare = Hash.compare

  (* Commit operations using ocaml-git *)
  type commit = Git.Commit.t

  let commit_make ~tree ~parents ~author ~committer ~message ~timestamp =
    let user_of_string s =
      (* Parse "Name <email>" format *)
      match String.index_opt s '<' with
      | None -> Git.User.v ~name:s ~email:"" ~date:timestamp ()
      | Some i ->
          let name = String.trim (String.sub s 0 i) in
          let rest = String.sub s (i + 1) (String.length s - i - 1) in
          let email =
            match String.index_opt rest '>' with
            | None -> rest
            | Some j -> String.sub rest 0 j
          in
          Git.User.v ~name ~email ~date:timestamp ()
    in
    Git.Commit.v ~tree:(git_hash_of_sha1 tree)
      ~parents:(List.map git_hash_of_sha1 parents)
      ~author:(user_of_string author) ~committer:(user_of_string committer)
      (Some message)

  let commit_tree c = sha1_of_git_hash (Git.Commit.tree c)
  let commit_parents c = List.map sha1_of_git_hash (Git.Commit.parents c)

  let user_to_string u =
    let name = Git.User.name u in
    let email = Git.User.email u in
    if email = "" then name else Fmt.str "%s <%s>" name email

  let commit_author c = user_to_string (Git.Commit.author c)
  let commit_committer c = user_to_string (Git.Commit.committer c)
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

  type entry =
    [ `Node of hash | `Contents of hash | `Contents_inlined of string ]

  let inline_threshold = 48

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
    let v =
      match kind with
      | `Contents h -> cid_of_sha256 h
      | `Node h -> cid_of_sha256 h
      | `Contents_inlined s ->
          (* Fallback: hash the content and store as CID *)
          cid_of_sha256 (Hash.sha256 s)
    in
    let entries = List.filter (fun (k, _) -> k <> name) entries in
    let entries =
      (name, (v, None))
      :: List.map (fun (k, (e : Atp.Mst.Raw.entry)) -> (k, (e.v, e.t))) entries
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
      (fun (key, (e : Atp.Mst.Raw.entry)) ->
        (key, `Contents (sha256_of_cid e.v)))
      entries

  let bytes_of_node node = Atp.Mst.Raw.encode_bytes node

  let node_of_bytes data : (node, [> `Msg of string ]) result =
    try Ok (Atp.Mst.Raw.decode_bytes data)
    with exn ->
      Error (`Msg ("failed to decode MST node: " ^ Printexc.to_string exn))

  let hash_node node =
    let data = bytes_of_node node in
    Hash.sha256 data

  let hash_contents data = Hash.sha256 data
  let hash_to_bytes = Hash.to_bytes
  let hash_to_hex = Hash.to_hex
  let hash_of_hex s : (hash, [> `Msg of string ]) result = Hash.sha256_of_hex s
  let hash_of_raw_bytes = Hash.sha256_of_bytes
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
            match List.assoc_opt key fields with Some (`Int i) -> i | _ -> 0L
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
          ( "parents",
            `List (List.map (fun h -> `Link (cid_of_sha256 h)) c.parents) );
          ("timestamp", `Int c.timestamp);
          ("tree", `Link (cid_of_sha256 c.tree));
        ]
    in
    Atp.Dagcbor.encode_string ~cid_format:`Atproto v

  let commit_hash c =
    let data = commit_to_bytes c in
    Hash.sha256 data
end
