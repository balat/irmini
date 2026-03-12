module SMap = Map.Make (String)
module SSet = Set.Make (String)

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
    mutable children : tree_node SMap.t; (* modifications *)
    mutable removed : SSet.t;
    resolved : (string, tree_node) Hashtbl.t; (* read cache *)
  }

  type t = tree_node

  let empty () =
    Node { state = Loaded F.empty_node; backend = None;
           children = SMap.empty; removed = SSet.empty; resolved = Hashtbl.create 0 }

  let of_hash ~backend hash =
    Node { state = Lazy { backend; hash }; backend = Some backend;
           children = SMap.empty; removed = SSet.empty; resolved = Hashtbl.create 0 }

  let shallow hash =
    Node { state = Shallow hash; backend = None;
           children = SMap.empty; removed = SSet.empty; resolved = Hashtbl.create 0 }

  let pruned hash =
    Node { state = Pruned hash; backend = None;
           children = SMap.empty; removed = SSet.empty; resolved = Hashtbl.create 0 }

  let rec of_concrete : concrete -> t = function
    | `Contents s -> Contents s
    | `Tree entries ->
        let children =
          List.fold_left (fun m (name, c) -> SMap.add name (of_concrete c) m)
            SMap.empty entries
        in
        Node { state = Loaded F.empty_node; backend = None;
               children; removed = SSet.empty; resolved = Hashtbl.create 0 }

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
        match SMap.find_opt name node.children with
        | Some child -> navigate child rest
        | None -> (
            if SSet.mem name node.removed then None
            else
              (* Check read cache *)
              match Hashtbl.find_opt node.resolved name with
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
                      Hashtbl.replace node.resolved name child;
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
                  (not (SSet.mem name node.removed))
                  && not (SMap.mem name node.children))
              |> List.map (fun (name, kind) ->
                  let k =
                    match kind with
                    | `Node _ -> `Node
                    | `Contents _ | `Contents_inlined _ -> `Contents
                  in
                  (name, k))
        in
        let child_entries =
          SMap.fold
            (fun name child acc ->
              let k =
                match child with Node _ -> `Node | Contents _ -> `Contents
              in
              (name, k) :: acc)
            node.children []
        in
        List.sort
          (fun (a, _) (b, _) -> String.compare a b)
          (base_entries @ child_entries)
    | _ -> []

  (* Resolve a child node for modification (add/remove at depth). *)
  let resolve_child node name =
    match SMap.find_opt name node.children with
    | Some c -> c
    | None -> (
        if SSet.mem name node.removed then empty ()
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
        let children = SMap.add name value node.children in
        let removed = SSet.remove name node.removed in
        Node { node with children; removed }
    | Node node, name :: rest ->
        let child = resolve_child node name in
        let new_child = add_at child rest value in
        let children = SMap.add name new_child node.children in
        Node { node with children }

  let add t path contents = add_at t path (Contents contents)
  let add_tree t path subtree = add_at t path subtree

  let rec remove t path =
    match (t, path) with
    | _, [] -> empty ()
    | Contents _, _ :: _ -> t
    | Node node, [ name ] ->
        let children = SMap.remove name node.children in
        let removed = SSet.add name node.removed in
        Node { node with children; removed }
    | Node node, name :: rest ->
        let child = resolve_child node name in
        let new_child = remove child rest in
        let children = SMap.add name new_child node.children in
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
                  if SSet.mem name node.removed then None
                  else if SMap.mem name node.children then None
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
          SMap.fold
            (fun name child acc -> (name, to_concrete child) :: acc)
            node.children []
        in
        let all =
          List.sort
            (fun (a, _) (b, _) -> String.compare a b)
            (entries @ child_entries)
        in
        `Tree all

  (* Write tree to backend and return hash *)
  let rec write_tree t ~inline_threshold ~inode ~(backend : hash Backend.t) : hash =
    match t with
    | Contents s ->
        let h = F.hash_contents s in
        backend.write h s;
        h
    | Node node ->
        resolve_state node;
        (* Compute child entries (recursively writing children) *)
        let child_entries =
          SMap.fold
            (fun name child acc ->
              let entry =
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
                      write_tree child ~inline_threshold ~inode ~backend
                    in
                    (name, (`Node child_hash : F.entry))
              in
              entry :: acc)
            node.children []
        in
        (match node.state with
        | Inode { hash; backend = ib } when inode ->
            (* Incremental update: only modify affected inode buckets *)
            Inode.update ~backend hash ~additions:child_entries
              ~removals:(SSet.elements node.removed)
        | Inode { hash; backend = ib } ->
            (* Inodes disabled: expand to flat node *)
            let base_entries = Inode.list_all ~backend:ib hash in
            let base =
              List.fold_left
                (fun n (name, entry) -> F.add n name entry)
                F.empty_node base_entries
            in
            let base =
              SSet.fold (fun name n -> F.remove n name) node.removed base
            in
            let final =
              List.fold_left
                (fun n (name, entry) -> F.add n name entry)
                base child_entries
            in
            let data = F.bytes_of_node final in
            let h = F.hash_node final in
            backend.write h data;
            h
        | _ ->
            (* Flat node: apply modifications, promote to inode if too large *)
            let base =
              match node.state with
              | Loaded n -> n
              | _ -> F.empty_node
            in
            let base =
              SSet.fold (fun name n -> F.remove n name) node.removed base
            in
            let final =
              List.fold_left
                (fun n (name, entry) -> F.add n name entry)
                base child_entries
            in
            if inode then begin
              let entries = F.list final in
              if List.length entries > Inode.max_entries then
                Inode.write entries ~backend
              else begin
                let data = F.bytes_of_node final in
                let h = F.hash_node final in
                backend.write h data;
                h
              end
            end else begin
              let data = F.bytes_of_node final in
              let h = F.hash_node final in
              backend.write h data;
              h
            end)

  let hash ?(inline_threshold = F.inline_threshold) ?(inode = true) t ~backend =
    write_tree t ~inline_threshold ~inode ~backend

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
                  SMap.fold
                    (fun name child acc -> go (path @ [ name ]) child acc)
                    node.children acc
              | _ -> acc)
          | `False fn -> (
              match node.state with
              | Lazy { hash; _ } -> fn hash
              | Shallow hash -> fn hash
              | Pruned hash -> fn hash
              | Loaded _ | Inode _ ->
                  SMap.fold
                    (fun name child acc -> go (path @ [ name ]) child acc)
                    node.children acc)
          | `Shallow fn -> (
              match node.state with
              | Shallow hash -> fn hash
              | _ ->
                  SMap.fold
                    (fun name child acc -> go (path @ [ name ]) child acc)
                    node.children acc))
    in
    go [] t init

  let clear ?depth:_ _t = ()

  let equal t1 t2 =
    (* Simple structural equality - could be optimized with hash comparison *)
    to_concrete t1 = to_concrete t2
end

module Git = Make (Codec.Git)
module Mst = Make (Codec.Mst)
