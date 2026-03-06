module Make (F : Codec.S) = struct
  type hash = F.hash
  type path = string list
  type concrete = [ `Contents of string | `Tree of (string * concrete) list ]

  (* Internal tree representation with lazy loading *)
  type node_state =
    | Loaded of F.node
    | Lazy of { backend : hash Backend.t; hash : hash }
    | Shallow of hash
    | Pruned of hash

  type tree_node =
    | Contents of string
    | Node of {
        mutable state : node_state;
        mutable children : (string * tree_node) list; (* modifications *)
        mutable removed : string list;
      }

  type t = tree_node

  let empty () =
    Node { state = Loaded F.empty_node; children = []; removed = [] }

  let of_hash ~backend hash =
    Node { state = Lazy { backend; hash }; children = []; removed = [] }

  let shallow hash = Node { state = Shallow hash; children = []; removed = [] }
  let pruned hash = Node { state = Pruned hash; children = []; removed = [] }

  let rec of_concrete : concrete -> t = function
    | `Contents s -> Contents s
    | `Tree entries ->
        let children =
          List.map (fun (name, c) -> (name, of_concrete c)) entries
        in
        Node { state = Loaded F.empty_node; children; removed = [] }

  (* Force loading of a lazy node *)
  let force_node state =
    match state with
    | Loaded n -> Some n
    | Lazy { backend; hash } -> (
        match backend.read hash with
        | Some data -> (
            match F.node_of_bytes data with Ok n -> Some n | Error _ -> None)
        | None -> None)
    | Shallow _ -> None
    | Pruned _ -> None

  (* Navigate to a path, returning the node and remaining path *)
  let rec navigate t path =
    match (t, path) with
    | _, [] -> Some (t, [])
    | Contents _, _ :: _ -> None
    | Node node, name :: rest -> (
        (* Check modifications first *)
        match List.assoc_opt name node.children with
        | Some child -> navigate child rest
        | None -> (
            if List.mem name node.removed then None
            else
              (* Try to load from underlying node *)
              match force_node node.state with
              | None -> None
              | Some loaded -> (
                  match F.find loaded name with
                  | None -> None
                  | Some (`Contents_inlined data) ->
                      navigate (Contents data) rest
                  | Some (`Contents hash) -> (
                      (* Load the content blob *)
                      match node.state with
                      | Lazy { backend; _ } -> (
                          match backend.read hash with
                          | Some data -> navigate (Contents data) rest
                          | None -> None)
                      | _ -> None)
                  | Some (`Node hash) -> (
                      match node.state with
                      | Lazy { backend; _ } ->
                          let child = of_hash ~backend hash in
                          navigate child rest
                      | _ -> None))))

  let find t path =
    match navigate t path with Some (Contents s, []) -> Some s | _ -> None

  let find_tree t path =
    match navigate t path with Some ((Node _ as n), []) -> Some n | _ -> None

  let mem t path = Option.is_some (navigate t path)

  let mem_tree t path =
    match navigate t path with Some (Node _, []) -> true | _ -> false

  let list t path =
    match navigate t path with
    | Some (Node node, []) -> (
        match force_node node.state with
        | None -> []
        | Some loaded ->
            let base_entries =
              F.list loaded
              |> List.filter (fun (name, _) ->
                  (not (List.mem name node.removed))
                  && not (List.mem_assoc name node.children))
              |> List.map (fun (name, kind) ->
                  let k =
                    match kind with
                    | `Node _ -> `Node
                    | `Contents _ | `Contents_inlined _ -> `Contents
                  in
                  (name, k))
            in
            let child_entries =
              List.map
                (fun (name, child) ->
                  let k =
                    match child with Node _ -> `Node | Contents _ -> `Contents
                  in
                  (name, k))
                node.children
            in
            List.sort
              (fun (a, _) (b, _) -> String.compare a b)
              (base_entries @ child_entries))
    | _ -> []

  (* Add contents at path, creating intermediate nodes as needed *)
  let rec add_at t path value =
    match (t, path) with
    | _, [] -> value
    | Contents _, _ :: _ ->
        (* Replace contents with a tree *)
        add_at (empty ()) path value
    | Node node, [ name ] ->
        let children =
          (name, value) :: List.filter (fun (n, _) -> n <> name) node.children
        in
        let removed = List.filter (( <> ) name) node.removed in
        Node { node with children; removed }
    | Node node, name :: rest ->
        let child =
          match List.assoc_opt name node.children with
          | Some c -> c
          | None -> (
              if List.mem name node.removed then empty ()
              else
                match force_node node.state with
                | None -> empty ()
                | Some loaded -> (
                    match F.find loaded name with
                    | Some (`Node hash) -> (
                        match node.state with
                        | Lazy { backend; _ } -> of_hash ~backend hash
                        | _ -> empty ())
                    | Some (`Contents _ | `Contents_inlined _) | None ->
                        empty ()))
        in
        let new_child = add_at child rest value in
        let children =
          (name, new_child)
          :: List.filter (fun (n, _) -> n <> name) node.children
        in
        Node { node with children }

  let add t path contents = add_at t path (Contents contents)
  let add_tree t path subtree = add_at t path subtree

  let rec remove t path =
    match (t, path) with
    | _, [] -> empty ()
    | Contents _, _ :: _ -> t
    | Node node, [ name ] ->
        let children = List.filter (fun (n, _) -> n <> name) node.children in
        let removed =
          if List.mem name node.removed then node.removed
          else name :: node.removed
        in
        Node { node with children; removed }
    | Node node, name :: rest ->
        let child =
          match List.assoc_opt name node.children with
          | Some c -> c
          | None -> (
              if List.mem name node.removed then empty ()
              else
                match force_node node.state with
                | None -> empty ()
                | Some loaded -> (
                    match F.find loaded name with
                    | Some (`Node hash) -> (
                        match node.state with
                        | Lazy { backend; _ } -> of_hash ~backend hash
                        | _ -> empty ())
                    | Some (`Contents _ | `Contents_inlined _) | None ->
                        empty ()))
        in
        let new_child = remove child rest in
        let children =
          (name, new_child)
          :: List.filter (fun (n, _) -> n <> name) node.children
        in
        Node { node with children }

  let rec to_concrete t =
    match t with
    | Contents s -> `Contents s
    | Node node ->
        let entries =
          match force_node node.state with
          | None -> []
          | Some loaded ->
              F.list loaded
              |> List.filter_map (fun (name, kind) ->
                  if List.mem name node.removed then None
                  else if List.mem_assoc name node.children then None
                  else
                    match kind with
                    | `Contents_inlined data ->
                        Some (name, `Contents data)
                    | `Contents hash -> (
                        match node.state with
                        | Lazy { backend; _ } -> (
                            match backend.read hash with
                            | Some data -> Some (name, `Contents data)
                            | None -> None)
                        | _ -> None)
                    | `Node hash -> (
                        match node.state with
                        | Lazy { backend; _ } ->
                            let child = of_hash ~backend hash in
                            Some (name, to_concrete child)
                        | _ -> None))
        in
        let child_entries =
          List.map
            (fun (name, child) -> (name, to_concrete child))
            node.children
        in
        let all =
          List.sort
            (fun (a, _) (b, _) -> String.compare a b)
            (entries @ child_entries)
        in
        `Tree all

  (* Write tree to backend and return hash *)
  let rec write_tree t ~inline_threshold ~(backend : hash Backend.t) : hash =
    match t with
    | Contents s ->
        let h = F.hash_contents s in
        backend.write h s;
        h
    | Node node ->
        (* First, get the base node *)
        let base =
          match force_node node.state with Some n -> n | None -> F.empty_node
        in
        (* Apply removals *)
        let base =
          List.fold_left (fun n name -> F.remove n name) base node.removed
        in
        (* Apply additions (recursively writing children) *)
        let final =
          List.fold_left
            (fun n (name, child) ->
              match child with
              | Contents s when inline_threshold > 0
                                && String.length s <= inline_threshold ->
                  (* Inline small contents directly in the node *)
                  F.add n name (`Contents_inlined s)
              | Contents s ->
                  let h = F.hash_contents s in
                  backend.write h s;
                  F.add n name (`Contents h)
              | Node _ ->
                  let child_hash =
                    write_tree child ~inline_threshold ~backend
                  in
                  F.add n name (`Node child_hash))
            base node.children
        in
        let data = F.bytes_of_node final in
        let h = F.hash_node final in
        backend.write h data;
        h

  let hash ?(inline_threshold = F.inline_threshold) t ~backend =
    write_tree t ~inline_threshold ~backend

  type 'a force = [ `True | `False of hash -> 'a | `Shallow of hash -> 'a ]

  let fold ?(force = `True) t init f =
    let rec go path t acc =
      match t with
      | Contents s -> f path (`Contents s) acc
      | Node node -> (
          let acc = f path `Tree acc in
          match force with
          | `True -> (
              match force_node node.state with
              | None -> acc
              | Some _loaded ->
                  (* Fold over children *)
                  List.fold_left
                    (fun acc (name, child) -> go (path @ [ name ]) child acc)
                    acc node.children)
          | `False fn -> (
              match node.state with
              | Lazy { hash; _ } -> fn hash
              | Shallow hash -> fn hash
              | Pruned hash -> fn hash
              | Loaded _ ->
                  List.fold_left
                    (fun acc (name, child) -> go (path @ [ name ]) child acc)
                    acc node.children)
          | `Shallow fn -> (
              match node.state with
              | Shallow hash -> fn hash
              | _ ->
                  List.fold_left
                    (fun acc (name, child) -> go (path @ [ name ]) child acc)
                    acc node.children))
    in
    go [] t init

  let clear ?depth:_ _t = ()

  let equal t1 t2 =
    (* Simple structural equality - could be optimized with hash comparison *)
    to_concrete t1 = to_concrete t2
end

module Git = Make (Codec.Git)
module Mst = Make (Codec.Mst)
