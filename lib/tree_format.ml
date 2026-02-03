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
  let node_of_bytes = Git.Tree.of_string
  let hash_node node = sha1_of_git_hash (Git.Tree.digest node)

  let hash_contents data =
    sha1_of_git_hash (Git.Hash.digest_string ~kind:`Blob data)
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
    let entries = List.filter (fun (k, _) -> k <> name) entries in
    let entries =
      (name, (v, None)) :: List.map (fun (k, e) -> (k, (e.v, e.t))) entries
    in
    let compressed = compress_keys entries in
    { node with e = compressed }

  let remove (node : node) name =
    let entries = decompress_keys node.e in
    let entries = List.filter (fun (k, _) -> k <> name) entries in
    let entries = List.map (fun (k, e) -> (k, (e.v, e.t))) entries in
    let compressed = compress_keys entries in
    { node with e = compressed }

  let list (node : node) =
    let entries = decompress_keys node.e in
    List.map (fun (key, e) -> (key, `Contents (sha256_of_cid e.v))) entries

  let bytes_of_node node = Atp.Mst.Raw.encode_bytes node

  let node_of_bytes data =
    try Ok (Atp.Mst.Raw.decode_bytes data)
    with _ -> Error (`Msg "failed to decode MST node")

  let hash_node node =
    let data = bytes_of_node node in
    Hash.sha256 data

  let hash_contents data = Hash.sha256 data
end
