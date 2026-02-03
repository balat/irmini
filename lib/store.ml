module Make (F : Tree_format.S) = struct
  type hash = F.hash

  module Tree = Tree.Make (F)
  module Commit = Commit.Make (F)

  type t = { backend : hash Backend.t }

  let create ~backend = { backend }
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

  let commit t ~tree ~parents ~message ~author =
    (* This is where delayed writes happen *)
    let tree_hash = Tree.hash tree ~backend:t.backend in
    let c = Commit.v ~tree:tree_hash ~parents ~author ~message () in
    let data = Commit.to_bytes c in
    let _ = t.backend.write data in
    Commit.hash c

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
      if Hash.equal h ancestor then true
      else if List.exists (Hash.equal h) visited then false
      else
        match read_commit t h with
        | None -> false
        | Some c ->
            let visited = h :: visited in
            List.exists (walk visited) (Commit.parents c)
    in
    Hash.equal ancestor descendant || walk [] descendant

  (* Find merge base using simple BFS *)
  let merge_base t h1 h2 =
    let rec ancestors_of h visited =
      if List.exists (Hash.equal h) visited then visited
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
      if List.exists (Hash.equal h) ancestors1 then Some h
      else
        match read_commit t h with
        | None -> None
        | Some c -> (
            match Commit.parents c with [] -> None | p :: _ -> find_common p)
    in
    find_common h2

  let commits_between t ~base ~head =
    let rec count h n =
      if Hash.equal h base then n
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

  let diff _t ~old:_ ~new_:_ =
    (* TODO: Implement tree diff *)
    Seq.empty
end

module Git = Make (Tree_format.Git)
module Mst = Make (Tree_format.Mst)
