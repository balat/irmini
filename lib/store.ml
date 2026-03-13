module Make (F : Codec.S) = struct
  type hash = F.hash

  module Tree = Tree.Make (F)
  module Commit = Commit.Make (F)

  type t = { backend : hash Backend.t }

  let create ~backend () = { backend }
  let backend t = t.backend

  let tree t ?at () =
    match at with
    | None -> Tree.empty ()
    | Some h -> Tree.of_hash ~backend:t.backend h

  let read_commit t h =
    match t.backend.read h with
    | None -> None
    | Some data -> (
        match Commit.of_bytes data with Ok c -> Some c | Error _ -> None)

  let read_tree t h = Tree.of_hash ~backend:t.backend h

  let checkout t ~branch =
    match t.backend.get_ref ("refs/heads/" ^ branch) with
    | None -> None
    | Some commit_hash -> (
        match read_commit t commit_hash with
        | None -> None
        | Some commit -> Some (read_tree t (Commit.tree commit)))

  let commit ?inline_threshold ?inode t ~tree ~parents ~message ~author =
    (* Buffer writes during tree traversal, flush as a single batch.
       This is critical for the disk backend where each individual write
       triggers a WAL sync (fsync). *)
    let pending_list = ref [] in
    let local_cache : (hash, string) Hashtbl.t = Hashtbl.create 128 in
    let buffered = {
      t.backend with
      write = (fun h data ->
        Hashtbl.replace local_cache h data;
        pending_list := (h, data) :: !pending_list);
      read = (fun h ->
        match Hashtbl.find_opt local_cache h with
        | Some _ as r -> r
        | None -> t.backend.read h);
    } in
    let tree_hash = Tree.hash ?inline_threshold ?inode tree ~backend:buffered in
    let c = Commit.v ~tree:tree_hash ~parents ~author ~message () in
    let data = Commit.to_bytes c in
    let h = Commit.hash c in
    pending_list := (h, data) :: !pending_list;
    t.backend.write_batch !pending_list;
    h

  let head t ~branch = t.backend.get_ref ("refs/heads/" ^ branch)
  let set_head t ~branch h = t.backend.set_ref ("refs/heads/" ^ branch) h

  let branches t =
    t.backend.list_refs ()
    |> List.filter_map (fun r ->
        if String.length r > 11 && String.sub r 0 11 = "refs/heads/" then
          Some (String.sub r 11 (String.length r - 11))
        else None)

  let update_branch t ~branch ~old ~new_ =
    t.backend.test_and_set_ref ("refs/heads/" ^ branch) ~test:old
      ~set:(Some new_)

  (* Simple ancestry check - walks parent chain *)
  let is_ancestor t ~ancestor ~descendant =
    let rec walk visited h =
      if F.hash_equal h ancestor then true
      else if List.exists (F.hash_equal h) visited then false
      else
        match read_commit t h with
        | None -> false
        | Some c ->
            let visited = h :: visited in
            List.exists (walk visited) (Commit.parents c)
    in
    F.hash_equal ancestor descendant || walk [] descendant

  (* Find merge base using simple BFS *)
  let merge_base t h1 h2 =
    let rec ancestors_of h visited =
      if List.exists (F.hash_equal h) visited then visited
      else
        match read_commit t h with
        | None -> h :: visited
        | Some c ->
            let visited = h :: visited in
            List.fold_left
              (fun acc p -> ancestors_of p acc)
              visited (Commit.parents c)
    in
    let ancestors1 = ancestors_of h1 [] in
    let rec find_common h =
      if List.exists (F.hash_equal h) ancestors1 then Some h
      else
        match read_commit t h with
        | None -> None
        | Some c -> (
            match Commit.parents c with [] -> None | p :: _ -> find_common p)
    in
    find_common h2

  let commits_between t ~base ~head =
    let rec count h n =
      if F.hash_equal h base then n
      else
        match read_commit t h with
        | None -> n
        | Some c -> (
            match Commit.parents c with [] -> n | p :: _ -> count p (n + 1))
    in
    count head 0

  type diff_entry =
    [ `Add of Tree.path * hash
    | `Remove of Tree.path
    | `Change of Tree.path * hash * hash ]

  let diff t ~old ~new_ =
    let old_tree = read_tree t old in
    let new_tree = read_tree t new_ in

    let rec diff_trees prefix old_tree new_tree =
      let old_entries = Tree.list old_tree [] in
      let new_entries = Tree.list new_tree [] in

      let old_names = List.map fst old_entries in
      let new_names = List.map fst new_entries in

      (* Entries only in old -> Remove *)
      let removed =
        old_names
        |> List.filter (fun name -> not (List.mem name new_names))
        |> List.to_seq
        |> Seq.map (fun name -> `Remove (prefix @ [ name ]))
      in

      (* Entries only in new -> Add *)
      let added =
        new_names
        |> List.filter (fun name -> not (List.mem name old_names))
        |> List.to_seq
        |> Seq.filter_map (fun name ->
            match Tree.find new_tree [ name ] with
            | Some content ->
                let hash = F.hash_contents content in
                Some (`Add (prefix @ [ name ], hash))
            | None ->
                (* It's a subtree - handled by added_subtrees recursion below *)
                None)
      in

      (* Entries in both -> check for changes *)
      let common =
        List.filter (fun name -> List.mem name new_names) old_names
      in
      let changes =
        common |> List.to_seq
        |> Seq.flat_map (fun name ->
            let path = prefix @ [ name ] in
            let old_kind = List.assoc name old_entries in
            let new_kind = List.assoc name new_entries in
            match (old_kind, new_kind) with
            | `Contents, `Contents -> (
                match
                  (Tree.find old_tree [ name ], Tree.find new_tree [ name ])
                with
                | Some old_c, Some new_c ->
                    let old_h = F.hash_contents old_c in
                    let new_h = F.hash_contents new_c in
                    if F.hash_equal old_h new_h then Seq.empty
                    else Seq.return (`Change (path, old_h, new_h))
                | _ -> Seq.empty)
            | `Node, `Node -> (
                match
                  ( Tree.find_tree old_tree [ name ],
                    Tree.find_tree new_tree [ name ] )
                with
                | Some old_sub, Some new_sub -> diff_trees path old_sub new_sub
                | _ -> Seq.empty)
            | `Contents, `Node ->
                (* Changed from contents to tree - remove old contents *)
                Seq.return (`Remove path)
                |> Seq.append
                     (match Tree.find_tree new_tree [ name ] with
                     | Some sub -> diff_trees path (Tree.empty ()) sub
                     | None -> Seq.empty)
            | `Node, `Contents ->
                (* Changed from tree to contents - add new contents *)
                (match Tree.find new_tree [ name ] with
                  | Some c ->
                      let new_h = F.hash_contents c in
                      Seq.return (`Add (path, new_h))
                  | None -> Seq.empty)
                |> Seq.append
                     (match Tree.find_tree old_tree [ name ] with
                     | Some sub -> diff_trees path sub (Tree.empty ())
                     | None -> Seq.empty))
      in

      (* Also recurse into added subtrees *)
      let added_subtrees =
        new_names
        |> List.filter (fun name -> not (List.mem name old_names))
        |> List.to_seq
        |> Seq.flat_map (fun name ->
            match Tree.find_tree new_tree [ name ] with
            | Some sub -> diff_trees (prefix @ [ name ]) (Tree.empty ()) sub
            | None -> Seq.empty)
      in

      (* Also recurse into removed subtrees *)
      let removed_subtrees =
        old_names
        |> List.filter (fun name -> not (List.mem name new_names))
        |> List.to_seq
        |> Seq.flat_map (fun name ->
            match Tree.find_tree old_tree [ name ] with
            | Some sub -> diff_trees (prefix @ [ name ]) sub (Tree.empty ())
            | None -> Seq.empty)
      in

      Seq.append removed
        (Seq.append added
           (Seq.append changes (Seq.append added_subtrees removed_subtrees)))
    in
    diff_trees [] old_tree new_tree
end

module Git = Make (Codec.Git)
module Mst = Make (Codec.Mst)
