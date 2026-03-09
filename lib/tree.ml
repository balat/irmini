module Make (F : Codec.S) = struct
  module Inode = Inode.Make (F)

  type hash = F.hash
  type path = string list
  type concrete = [ `Contents of string | `Tree of (string * concrete) list ]

  (* Internal tree representation with lazy loading *)
  type node_state =
    | Loaded of F.node
    | Inode of { backend : hash Backend.t; hash : hash }
    | Lazy of { backend : hash Backend.t; hash : hash }
    | Shallow of hash
    | Pruned of hash

  type tree_node =
    | Contents of string
    | Node of node_record

  and node_record = {
    mutable state : node_state;
    backend : hash Backend.t option;
    mutable children : (string * tree_node) list; (* modifications *)
    mutable removed : string list;
    mutable resolved : (string * tree_node) list; (* read cache *)
  }

  type t = tree_node

  let empty () =
    Node { state = Loaded F.empty_node; backend = None;
           children = []; removed = []; resolved = [] }

  let of_hash ~backend hash =
    Node { state = Lazy { backend; hash }; backend = Some backend;
           children = []; removed = []; resolved = [] }

  let shallow hash =
    Node { state = Shallow hash; backend = None;
           children = []; removed = []; resolved = [] }

  let pruned hash =
    Node { state = Pruned hash; backend = None;
           children = []; removed = []; resolved = [] }

  let rec of_concrete : concrete -> t = function
    | `Contents s -> Contents s
    | `Tree entries ->
        let children =
          List.map (fun (name, c) -> (name, of_concrete c)) entries
        in
        Node { state = Loaded F.empty_node; backend = None;
               children; removed = []; resolved = [] }

  (* Resolve a lazy node: load from backend, detect inode format. *)
  let resolve_state node =
    match node.state with
    | Loaded _ | Inode _ | Shallow _ | Pruned _ -> ()
    | Lazy { backend; hash } -> (
        match backend.read hash with
        | None -> ()
        | Some data ->
            if Inode.is_inode data then
              node.state <- Inode { backend; hash }
            else (
              match F.node_of_bytes data with
              | Ok n -> node.state <- Loaded n
              | Error _ -> ()))

  (* Look up a single entry by name, handling both flat nodes and inodes. *)
  let resolve_entry node name =
    resolve_state node;
    match node.state with
    | Loaded n -> F.find n name
    | Inode { backend; hash } -> Inode.find ~backend hash name
    | _ -> None

  (* List all entries, handling both flat nodes and inodes. *)
  let resolve_entries node =
    resolve_state node;
    match node.state with
    | Loaded n -> Some (F.list n)
    | Inode { backend; hash } -> Some (Inode.list_all ~backend hash)
    | _ -> None

  (* Navigate to a path, returning the node and remaining path.
     Resolved children are cached in [node.resolved] to avoid repeated
     deserialization on subsequent reads. *)
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
              (* Check read cache *)
              match List.assoc_opt name node.resolved with
              | Some child -> navigate child rest
              | None ->
                  let resolved =
                    match resolve_entry node name with
                    | None -> None
                    | Some (`Contents_inlined data) ->
                        Some (Contents data)
                    | Some (`Contents hash) -> (
                        match node.backend with
                        | Some backend -> (
                            match backend.read hash with
                            | Some data -> Some (Contents data)
                            | None -> None)
                        | None -> None)
                    | Some (`Node hash) -> (
                        match node.backend with
                        | Some backend -> Some (of_hash ~backend hash)
                        | None -> None)
                  in
                  match resolved with
                  | None -> None
                  | Some child ->
                      node.resolved <- (name, child) :: node.resolved;
                      navigate child rest))

  let find t path =
    match navigate t path with Some (Contents s, []) -> Some s | _ -> None

  let find_tree t path =
    match navigate t path with Some ((Node _ as n), []) -> Some n | _ -> None

  let mem t path = Option.is_some (navigate t path)

  let mem_tree t path =
    match navigate t path with Some (Node _, []) -> true | _ -> false

  let list t path =
    match navigate t path with
    | Some (Node node, []) ->
        let base_entries =
          match resolve_entries node with
          | None -> []
          | Some entries ->
              entries
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
          (base_entries @ child_entries)
    | _ -> []

  (* Resolve a child node for modification (add/remove at depth). *)
  let resolve_child node name =
    match List.assoc_opt name node.children with
    | Some c -> c
    | None -> (
        if List.mem name node.removed then empty ()
        else
          match resolve_entry node name with
          | Some (`Node hash) -> (
              match node.backend with
              | Some backend -> of_hash ~backend hash
              | None -> empty ())
          | Some (`Contents _ | `Contents_inlined _) | None -> empty ())

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
        let child = resolve_child node name in
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
        let child = resolve_child node name in
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
          match resolve_entries node with
          | None -> []
          | Some all_entries ->
              all_entries
              |> List.filter_map (fun (name, kind) ->
                  if List.mem name node.removed then None
                  else if List.mem_assoc name node.children then None
                  else
                    match kind with
                    | `Contents_inlined data -> Some (name, `Contents data)
                    | `Contents hash -> (
                        match node.backend with
                        | Some backend -> (
                            match backend.read hash with
                            | Some data -> Some (name, `Contents data)
                            | None -> None)
                        | None -> None)
                    | `Node hash -> (
                        match node.backend with
                        | Some backend ->
                            let child = of_hash ~backend hash in
                            Some (name, to_concrete child)
                        | None -> None))
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
        resolve_state node;
        (* Compute child entries (recursively writing children) *)
        let child_entries =
          List.map
            (fun (name, child) ->
              match child with
              | Contents s
                when inline_threshold > 0
                     && String.length s <= inline_threshold ->
                  (name, (`Contents_inlined s : F.entry))
              | Contents s ->
                  let h = F.hash_contents s in
                  backend.write h s;
                  (name, (`Contents h : F.entry))
              | Node _ ->
                  let child_hash =
                    write_tree child ~inline_threshold ~backend
                  in
                  (name, (`Node child_hash : F.entry)))
            node.children
        in
        (match node.state with
        | Inode { hash; _ } ->
            (* Incremental update: only modify affected inode buckets *)
            Inode.update ~backend hash ~additions:child_entries
              ~removals:node.removed
        | _ ->
            (* Flat node: apply modifications, promote to inode if too large *)
            let base =
              match node.state with
              | Loaded n -> n
              | _ -> F.empty_node
            in
            let base =
              List.fold_left (fun n name -> F.remove n name) base node.removed
            in
            let final =
              List.fold_left
                (fun n (name, entry) -> F.add n name entry)
                base child_entries
            in
            let entries = F.list final in
            if List.length entries > Inode.max_entries then
              Inode.write entries ~backend
            else begin
              let data = F.bytes_of_node final in
              let h = F.hash_node final in
              backend.write h data;
              h
            end)

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
              resolve_state node;
              match node.state with
              | Loaded _ | Inode _ ->
                  List.fold_left
                    (fun acc (name, child) -> go (path @ [ name ]) child acc)
                    acc node.children
              | _ -> acc)
          | `False fn -> (
              match node.state with
              | Lazy { hash; _ } -> fn hash
              | Shallow hash -> fn hash
              | Pruned hash -> fn hash
              | Loaded _ | Inode _ ->
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
