module Make (F : Codec.S) = struct
  type hash = F.hash

  module Store = Store.Make (F)
  module Tree = Store.Tree
  module Commit = Store.Commit

  type status =
    [ `In_sync
    | `Local_ahead of int
    | `Remote_ahead of int
    | `Diverged of int * int (* local, remote *)
    | `Trees_differ ]

  (* Extract subtree at prefix from a tree *)
  let extract_subtree tree prefix = Tree.find_tree tree prefix

  (* Check if a commit touches the given prefix *)
  let commit_touches_prefix store commit prefix =
    let tree = Store.read_tree store (Commit.tree commit) in
    Option.is_some (Tree.find_tree tree prefix)

  (* Split: Extract subtree history into a new store *)
  let split store ~prefix =
    let backend = Backend.Memory.create_with_hash F.hash_to_hex F.hash_equal in
    let new_store = Store.create ~backend in

    (* Walk commits and rewrite those touching prefix *)
    let rec rewrite_commit old_hash rewritten =
      if List.mem_assoc old_hash rewritten then
        (List.assoc old_hash rewritten, rewritten)
      else
        match Store.read_commit store old_hash with
        | None -> (old_hash, rewritten)
        | Some commit -> (
            if not (commit_touches_prefix store commit prefix) then
              (* Skip commits not touching prefix *)
              match Commit.parents commit with
              | [] -> (old_hash, rewritten)
              | p :: _ -> rewrite_commit p rewritten
            else
              (* Rewrite parents first *)
              let parents, rewritten =
                List.fold_left
                  (fun (parents, rw) p ->
                    let new_p, rw = rewrite_commit p rw in
                    (new_p :: parents, rw))
                  ([], rewritten) (Commit.parents commit)
              in
              let parents = List.rev parents in

              (* Extract subtree *)
              let tree = Store.read_tree store (Commit.tree commit) in
              match extract_subtree tree prefix with
              | None -> (old_hash, rewritten)
              | Some subtree ->
                  let new_hash =
                    Store.commit new_store ~tree:subtree ~parents
                      ~message:(Commit.message commit)
                      ~author:(Commit.author commit)
                  in
                  (new_hash, (old_hash, new_hash) :: rewritten))
    in

    (* Start from main branch head *)
    (match Store.head store ~branch:"main" with
    | Some head ->
        let new_head, _ = rewrite_commit head [] in
        Store.set_head new_store ~branch:"main" new_head
    | None -> ());

    new_store

  (* Add: Add external repo as subtree *)
  let add store ~prefix ~source =
    match Store.head source ~branch:"main" with
    | None -> failwith "Source has no main branch"
    | Some source_head -> (
        match Store.read_commit source source_head with
        | None -> failwith "Cannot read source commit"
        | Some source_commit ->
            let source_tree =
              Store.read_tree source (Commit.tree source_commit)
            in

            (* Get current tree or empty *)
            let current_tree =
              match Store.head store ~branch:"main" with
              | None -> Tree.empty ()
              | Some h -> (
                  match Store.read_commit store h with
                  | None -> Tree.empty ()
                  | Some c -> Store.read_tree store (Commit.tree c))
            in

            (* Add source tree at prefix *)
            let new_tree = Tree.add_tree current_tree prefix source_tree in

            let parents =
              match Store.head store ~branch:"main" with
              | None -> []
              | Some h -> [ h ]
            in

            let message =
              Printf.sprintf "Add '%s' from external source"
                (String.concat "/" prefix)
            in

            let new_head =
              Store.commit store ~tree:new_tree ~parents ~message
                ~author:"irmin-subtree"
            in
            Store.set_head store ~branch:"main" new_head;
            new_head)

  (* Pull: Update subtree from external source *)
  let pull store ~prefix ~source =
    match Store.head source ~branch:"main" with
    | None -> Error (`Conflict [])
    | Some source_head -> (
        match Store.read_commit source source_head with
        | None -> Error (`Conflict [])
        | Some source_commit ->
            let source_tree =
              Store.read_tree source (Commit.tree source_commit)
            in

            let current_tree =
              match Store.head store ~branch:"main" with
              | None -> Tree.empty ()
              | Some h -> (
                  match Store.read_commit store h with
                  | None -> Tree.empty ()
                  | Some c -> Store.read_tree store (Commit.tree c))
            in

            (* Replace subtree at prefix *)
            let new_tree =
              let without = Tree.remove current_tree prefix in
              Tree.add_tree without prefix source_tree
            in

            let parents =
              match Store.head store ~branch:"main" with
              | None -> []
              | Some h -> [ h ]
            in

            let message =
              Printf.sprintf "Pull updates into '%s'" (String.concat "/" prefix)
            in

            let new_head =
              Store.commit store ~tree:new_tree ~parents ~message
                ~author:"irmin-subtree"
            in
            Store.set_head store ~branch:"main" new_head;
            Ok new_head)

  (* Push: Push subtree changes to external repo *)
  let push store ~prefix ~target =
    match Store.head store ~branch:"main" with
    | None -> failwith "Store has no main branch"
    | Some head -> (
        match Store.read_commit store head with
        | None -> failwith "Cannot read store commit"
        | Some commit -> (
            let tree = Store.read_tree store (Commit.tree commit) in
            match extract_subtree tree prefix with
            | None -> failwith "No subtree at prefix"
            | Some subtree ->
                let parents =
                  match Store.head target ~branch:"main" with
                  | None -> []
                  | Some h -> [ h ]
                in

                let message =
                  Printf.sprintf "Push from '%s'" (String.concat "/" prefix)
                in

                let new_head =
                  Store.commit target ~tree:subtree ~parents ~message
                    ~author:"irmin-subtree"
                in
                Store.set_head target ~branch:"main" new_head;
                new_head))

  (* Status: Compare subtree with external repo *)
  let status store ~prefix ~external_ =
    let local_head = Store.head store ~branch:"main" in
    let remote_head = Store.head external_ ~branch:"main" in

    match (local_head, remote_head) with
    | None, None -> `In_sync
    | None, Some _ -> `Remote_ahead 1
    | Some _, None -> `Local_ahead 1
    | Some lh, Some rh -> (
        (* Get subtree hash from local *)
        let local_tree_hash =
          match Store.read_commit store lh with
          | None -> None
          | Some c -> (
              let tree = Store.read_tree store (Commit.tree c) in
              match Tree.find_tree tree prefix with
              | None -> None
              | Some t -> Some (Tree.hash t ~backend:(Store.backend store)))
        in

        (* Get tree hash from remote *)
        let remote_tree_hash =
          match Store.read_commit external_ rh with
          | None -> None
          | Some c -> Some (Commit.tree c)
        in

        match (local_tree_hash, remote_tree_hash) with
        | None, None -> `In_sync
        | None, Some _ -> `Remote_ahead 1
        | Some _, None -> `Local_ahead 1
        | Some lt, Some rt ->
            if F.hash_equal lt rt then `In_sync
            else if
              (* Check ancestry *)
              Store.is_ancestor external_ ~ancestor:rt ~descendant:lt
            then
              `Local_ahead (Store.commits_between external_ ~base:rt ~head:lt)
            else if Store.is_ancestor external_ ~ancestor:lt ~descendant:rt then
              `Remote_ahead (Store.commits_between external_ ~base:lt ~head:rt)
            else `Trees_differ)
end

module Git = Make (Codec.Git)
module Mst = Make (Codec.Mst)
