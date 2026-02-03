(** Git interoperability using ocaml-git.

    Provides bidirectional support for reading and writing Git repositories. *)

(* Convert between irmin Hash.sha1 and Git.Hash.t *)
let git_hash_of_sha1 (h : Hash.sha1) : Git.Hash.t =
  Git.Hash.of_raw_string (Hash.to_bytes h)

let sha1_of_git_hash (h : Git.Hash.t) : Hash.sha1 =
  Hash.sha1_of_bytes (Git.Hash.to_raw_string h)

(* Loose object path: .git/objects/ab/cdef... *)
let loose_object_path git_dir hash =
  let hex = Git.Hash.to_hex hash in
  let dir = String.sub hex 0 2 in
  let file = String.sub hex 2 (String.length hex - 2) in
  Filename.concat git_dir (Filename.concat "objects" (Filename.concat dir file))

(* Read loose object - returns raw content without header *)
let read_loose_object ~fs git_dir hash =
  let path = loose_object_path git_dir hash in
  let full_path = Eio.Path.(fs / path) in
  try
    let data = Eio.Path.load full_path in
    (* TODO: Add zlib decompression *)
    Git.Value.of_string_with_header data
  with _ -> Error (`Msg "object not found")

(* Write loose object *)
let write_loose_object ~fs git_dir (value : Git.Value.t) =
  let hash = Git.Value.digest value in
  let path = loose_object_path git_dir hash in
  let full_path = Eio.Path.(fs / path) in

  (* Create directory if needed *)
  let dir = Filename.dirname path in
  let dir_path = Eio.Path.(fs / dir) in
  (try Eio.Path.mkdir ~perm:0o755 dir_path with _ -> ());

  (* Write object with header *)
  let data = Git.Value.to_string value in
  (* TODO: Add zlib compression *)
  Eio.Path.save ~create:(`Or_truncate 0o444) full_path data;
  hash

(* Read reference *)
let read_ref ~fs ~git_dir name =
  let path = Filename.concat git_dir name in
  let full_path = Eio.Path.(fs / path) in
  try
    let content = Eio.Path.load full_path in
    let content = String.trim content in
    (* Check for symbolic ref *)
    if String.length content > 5 && String.sub content 0 5 = "ref: " then
      let target = String.sub content 5 (String.length content - 5) in
      let target_path = Eio.Path.(fs / Filename.concat git_dir target) in
      try
        let target_content = Eio.Path.load target_path in
        Some (Git.Hash.of_hex (String.trim target_content))
      with _ -> None
    else Some (Git.Hash.of_hex content)
  with _ -> None

(* Write reference *)
let write_ref ~fs ~git_dir name hash =
  let path = Filename.concat git_dir name in
  let full_path = Eio.Path.(fs / path) in
  let dir = Filename.dirname path in
  let dir_path = Eio.Path.(fs / dir) in
  (try Eio.Path.mkdir ~perm:0o755 dir_path with _ -> ());
  let content = Git.Hash.to_hex hash ^ "\n" in
  Eio.Path.save ~create:(`Or_truncate 0o644) full_path content

(* List references *)
let list_refs ~fs ~git_dir =
  let refs_dir = Filename.concat git_dir "refs" in
  let refs_path = Eio.Path.(fs / refs_dir) in
  let rec collect_refs path prefix acc =
    try
      let entries = Eio.Path.read_dir path in
      List.fold_left
        (fun acc entry ->
          let entry_path = Eio.Path.(path / entry) in
          let ref_name = if prefix = "" then entry else prefix ^ "/" ^ entry in
          if Eio.Path.is_directory entry_path then
            collect_refs entry_path ref_name acc
          else ("refs/" ^ ref_name) :: acc)
        acc entries
    with _ -> acc
  in
  collect_refs refs_path "" []

(* Create Git backend using ocaml-git types *)
let git_backend ~fs ~git_dir : Hash.sha1 Backend.t =
  {
    read =
      (fun hash ->
        let git_hash = git_hash_of_sha1 hash in
        match read_loose_object ~fs git_dir git_hash with
        | Ok value -> Some (Git.Value.to_string_without_header value)
        | Error _ -> None);
    write =
      (fun data ->
        (* Default to blob for raw data writes *)
        let blob = Git.Blob.of_string data in
        let value = Git.Value.blob blob in
        let git_hash = write_loose_object ~fs git_dir value in
        sha1_of_git_hash git_hash);
    exists =
      (fun hash ->
        let git_hash = git_hash_of_sha1 hash in
        let path = loose_object_path git_dir git_hash in
        let full_path = Eio.Path.(fs / path) in
        Eio.Path.is_file full_path);
    get_ref =
      (fun name -> Option.map sha1_of_git_hash (read_ref ~fs ~git_dir name));
    set_ref =
      (fun name hash -> write_ref ~fs ~git_dir name (git_hash_of_sha1 hash));
    test_and_set_ref =
      (fun name ~test ~set ->
        let current = read_ref ~fs ~git_dir name in
        let matches =
          match (test, current) with
          | None, None -> true
          | Some t, Some c -> Git.Hash.equal (git_hash_of_sha1 t) c
          | _ -> false
        in
        if matches then (
          (match set with
          | None -> (
              let path = Filename.concat git_dir name in
              let full_path = Eio.Path.(fs / path) in
              try Eio.Path.unlink full_path with _ -> ())
          | Some h -> write_ref ~fs ~git_dir name (git_hash_of_sha1 h));
          true)
        else false);
    list_refs = (fun () -> list_refs ~fs ~git_dir);
    write_batch =
      (fun objects ->
        List.map
          (fun data ->
            let blob = Git.Blob.of_string data in
            let value = Git.Value.blob blob in
            let git_hash = write_loose_object ~fs git_dir value in
            sha1_of_git_hash git_hash)
          objects);
    flush = (fun () -> ());
    close = (fun () -> ());
  }

(** Write a tree value to the git store *)
let write_tree ~fs ~git_dir (tree : Git.Tree.t) =
  let value = Git.Value.tree tree in
  write_loose_object ~fs git_dir value

(** Write a commit value to the git store *)
let write_commit ~fs ~git_dir (commit : Git.Commit.t) =
  let value = Git.Value.commit commit in
  write_loose_object ~fs git_dir value

(** Read a tree from the git store *)
let read_tree ~fs ~git_dir hash =
  match read_loose_object ~fs git_dir hash with
  | Ok (Git.Value.Tree t) -> Some t
  | _ -> None

(** Read a commit from the git store *)
let read_commit ~fs ~git_dir hash =
  match read_loose_object ~fs git_dir hash with
  | Ok (Git.Value.Commit c) -> Some c
  | _ -> None

(* Public API *)

let import_git ~sw:_ ~fs ~git_dir =
  let backend = git_backend ~fs ~git_dir in
  Store.Git.create ~backend

let init_git ~sw:_ ~fs ~path =
  let git_dir = Filename.concat path ".git" in
  let git_path = Eio.Path.(fs / git_dir) in

  (* Create .git structure *)
  Eio.Path.mkdir ~perm:0o755 git_path;
  Eio.Path.mkdir ~perm:0o755 Eio.Path.(git_path / "objects");
  Eio.Path.mkdir ~perm:0o755 Eio.Path.(git_path / "refs");
  Eio.Path.mkdir ~perm:0o755 Eio.Path.(git_path / "refs" / "heads");

  (* Write HEAD *)
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(git_path / "HEAD")
    "ref: refs/heads/main\n";

  import_git ~sw:() ~fs ~git_dir

let read_object ~sw:_ ~fs ~git_dir hash =
  let git_hash = git_hash_of_sha1 hash in
  match read_loose_object ~fs git_dir git_hash with
  | Ok value ->
      let kind =
        match Git.Value.kind value with
        | `Blob -> "blob"
        | `Tree -> "tree"
        | `Commit -> "commit"
        | `Tag -> "tag"
      in
      Ok (kind, Git.Value.to_string_without_header value)
  | Error _ as e -> e

let write_object ~sw:_ ~fs ~git_dir ~typ data =
  let value =
    match typ with
    | "blob" -> Git.Value.blob (Git.Blob.of_string data)
    | "tree" -> Git.Value.tree (Git.Tree.of_string_exn data)
    | "commit" -> Git.Value.commit (Git.Commit.of_string_exn data)
    | "tag" -> Git.Value.tag (Git.Tag.of_string_exn data)
    | _ -> invalid_arg ("unknown object type: " ^ typ)
  in
  let git_hash = write_loose_object ~fs git_dir value in
  sha1_of_git_hash git_hash

let read_ref ~sw:_ ~fs ~git_dir name =
  Option.map sha1_of_git_hash (read_ref ~fs ~git_dir name)

let write_ref ~sw:_ ~fs ~git_dir name hash =
  write_ref ~fs ~git_dir name (git_hash_of_sha1 hash)

let list_refs ~sw:_ ~fs ~git_dir = list_refs ~fs ~git_dir

let read_pack_index ~sw:_ ~fs:_ ~path:_ =
  (* TODO: Implement pack index reading *)
  []

let read_from_pack ~sw:_ ~fs:_ ~pack:_ ~offset:_ =
  (* TODO: Implement pack file reading *)
  Error (`Msg "pack file reading not yet implemented")
