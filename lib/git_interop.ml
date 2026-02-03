(** Git interoperability using ocaml-git.

    Provides bidirectional support for reading and writing Git repositories. *)

(* Convert between irmin Hash.sha1 and Git.Hash.t *)
let git_hash_of_sha1 (h : Hash.sha1) : Git.Hash.t =
  Git.Hash.of_raw_string (Hash.to_bytes h)

let sha1_of_git_hash (h : Git.Hash.t) : Hash.sha1 =
  Hash.sha1_of_bytes (Git.Hash.to_raw_string h)

(* Detect object type from content.
   Commits start with "tree ", trees have binary format with mode prefixes. *)
let detect_object_type data =
  if String.length data >= 5 && String.sub data 0 5 = "tree " then `Commit
  else if String.length data >= 2 && data.[0] >= '1' && data.[0] <= '7' then
    (* Tree entries start with mode like "100644 " or "40000 " *)
    `Tree
  else `Blob

(* Create Git backend from a Git.Repository.t *)
let git_backend (repo : Git.Repository.t) : Hash.sha1 Backend.t =
  {
    read =
      (fun hash ->
        let git_hash = git_hash_of_sha1 hash in
        match Git.Repository.read repo git_hash with
        | Ok value -> Some (Git.Value.to_string_without_header value)
        | Error _ -> None);
    write =
      (fun _expected_hash data ->
        (* Detect object type and write with correct Git wrapper *)
        let value =
          match detect_object_type data with
          | `Blob -> Git.Value.blob (Git.Blob.of_string data)
          | `Tree -> Git.Value.tree (Git.Tree.of_string_exn data)
          | `Commit -> Git.Value.commit (Git.Commit.of_string_exn data)
        in
        let _git_hash = Git.Repository.write repo value in
        ());
    exists =
      (fun hash ->
        let git_hash = git_hash_of_sha1 hash in
        Git.Repository.exists repo git_hash);
    get_ref =
      (fun name ->
        Option.map sha1_of_git_hash (Git.Repository.read_ref repo name));
    set_ref =
      (fun name hash ->
        Git.Repository.write_ref repo name (git_hash_of_sha1 hash));
    test_and_set_ref =
      (fun name ~test ~set ->
        let current = Git.Repository.read_ref repo name in
        let matches =
          match (test, current) with
          | None, None -> true
          | Some t, Some c -> Git.Hash.equal (git_hash_of_sha1 t) c
          | _ -> false
        in
        if matches then (
          (match set with
          | None -> Git.Repository.delete_ref repo name
          | Some h -> Git.Repository.write_ref repo name (git_hash_of_sha1 h));
          true)
        else false);
    list_refs = (fun () -> Git.Repository.list_refs repo);
    write_batch =
      (fun objects ->
        List.iter
          (fun (_expected_hash, data) ->
            let value =
              match detect_object_type data with
              | `Blob -> Git.Value.blob (Git.Blob.of_string data)
              | `Tree -> Git.Value.tree (Git.Tree.of_string_exn data)
              | `Commit -> Git.Value.commit (Git.Commit.of_string_exn data)
            in
            let _git_hash = Git.Repository.write repo value in
            ())
          objects);
    flush = (fun () -> ());
    close = (fun () -> ());
  }

(* Public API *)

let import_git ~sw:_ ~fs ~git_dir =
  let repo = Git.Repository.open_bare ~fs git_dir in
  let backend = git_backend repo in
  Store.Git.create ~backend

let open_git ~sw:_ ~fs ~path =
  let repo = Git.Repository.open_repo ~fs path in
  let backend = git_backend repo in
  Store.Git.create ~backend

let init_git ~sw:_ ~fs ~path =
  let repo = Git.Repository.init ~fs path in
  let backend = git_backend repo in
  Store.Git.create ~backend

let read_object ~sw:_ ~fs ~git_dir hash :
    (string * string, [> `Msg of string ]) result =
  let repo = Git.Repository.open_bare ~fs git_dir in
  let git_hash = git_hash_of_sha1 hash in
  match Git.Repository.read repo git_hash with
  | Ok value ->
      let kind =
        match Git.Value.kind value with
        | `Blob -> "blob"
        | `Tree -> "tree"
        | `Commit -> "commit"
        | `Tag -> "tag"
      in
      Ok (kind, Git.Value.to_string_without_header value)
  | Error (`Msg m) -> Error (`Msg m)

let write_object ~sw:_ ~fs ~git_dir ~typ data =
  let repo = Git.Repository.open_bare ~fs git_dir in
  let value =
    match typ with
    | "blob" -> Git.Value.blob (Git.Blob.of_string data)
    | "tree" -> Git.Value.tree (Git.Tree.of_string_exn data)
    | "commit" -> Git.Value.commit (Git.Commit.of_string_exn data)
    | "tag" -> Git.Value.tag (Git.Tag.of_string_exn data)
    | _ -> invalid_arg ("unknown object type: " ^ typ)
  in
  let git_hash = Git.Repository.write repo value in
  sha1_of_git_hash git_hash

let read_ref ~sw:_ ~fs ~git_dir name =
  let repo = Git.Repository.open_bare ~fs git_dir in
  Option.map sha1_of_git_hash (Git.Repository.read_ref repo name)

let write_ref ~sw:_ ~fs ~git_dir name hash =
  let repo = Git.Repository.open_bare ~fs git_dir in
  Git.Repository.write_ref repo name (git_hash_of_sha1 hash)

let list_refs ~sw:_ ~fs ~git_dir =
  let repo = Git.Repository.open_bare ~fs git_dir in
  Git.Repository.list_refs repo
