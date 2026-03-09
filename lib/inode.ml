(** Inode: structural sharing for large tree nodes.

    Entries are distributed across a 32-way trie based on the hash of their
    name. Each leaf holds at most [max_entries] entries as a regular flat node.
    Internal (routing) nodes are serialized with a [\x02] marker followed by
    (bucket_index, child_hash) pairs.

    Serialization format for inode tree nodes:
    {v \x02 <count:1 byte> (<index:1 byte> <hash:N bytes>)* v}
    where N is the hash size (20 for SHA-1, 32 for SHA-256). *)

module Make (F : Codec.S) = struct
  type hash = F.hash

  let max_entries = 32
  let branching = 32
  let log_branching = 5

  let inode_tag = 0x02

  let is_inode data =
    String.length data > 0 && Char.code data.[0] = inode_tag

  (* Hash size in bytes, computed once. *)
  let hash_size = String.length (F.hash_to_bytes (F.hash_contents ""))

  let bucket ~depth name =
    let h = Hashtbl.hash name in
    (h lsr (depth * log_branching)) land (branching - 1)

  (* --- Serialization of inode tree (routing) nodes --- *)

  let serialize_inode children =
    let buf = Buffer.create (2 + (branching * (1 + hash_size))) in
    Buffer.add_char buf (Char.chr inode_tag);
    (* Count non-empty children *)
    let count = Array.fold_left (fun n c ->
        match c with None -> n | Some _ -> n + 1) 0 children in
    Buffer.add_uint8 buf count;
    Array.iteri (fun i c ->
        match c with
        | None -> ()
        | Some h ->
            Buffer.add_uint8 buf i;
            Buffer.add_string buf (F.hash_to_bytes h))
      children;
    Buffer.contents buf

  let parse_inode data =
    let count = Char.code data.[1] in
    let children = Array.make branching None in
    let pos = ref 2 in
    for _ = 1 to count do
      let idx = Char.code data.[!pos] in
      let raw = String.sub data (!pos + 1) hash_size in
      children.(idx) <- Some (F.hash_of_raw_bytes raw);
      pos := !pos + 1 + hash_size
    done;
    children

  (* --- Flat node helpers --- *)

  let entries_of_node node =
    F.list node

  let node_of_entries entries =
    List.fold_left (fun n (name, entry) -> F.add n name entry) F.empty_node entries

  let write_flat entries ~(backend : hash Backend.t) =
    let node = node_of_entries entries in
    let data = F.bytes_of_node node in
    let h = F.hash_node node in
    backend.write h data;
    h

  let hash_inode_data data =
    F.hash_contents data

  (* --- Write an inode trie from a flat list of entries --- *)

  let rec write_entries ~depth entries ~(backend : hash Backend.t) =
    if List.length entries <= max_entries then
      write_flat entries ~backend
    else begin
      let buckets = Array.make branching [] in
      List.iter (fun ((name, _) as entry) ->
          let idx = bucket ~depth name in
          buckets.(idx) <- entry :: buckets.(idx))
        entries;
      let children = Array.map (fun bucket ->
          match bucket with
          | [] -> None
          | entries -> Some (write_entries ~depth:(depth + 1) entries ~backend))
        buckets
      in
      let data = serialize_inode children in
      let h = hash_inode_data data in
      backend.write h data;
      h
    end

  let write entries ~backend = write_entries ~depth:0 entries ~backend

  (* --- Find a single entry by name --- *)

  let rec find_at ~depth ~(backend : hash Backend.t) hash name =
    match backend.read hash with
    | None -> None
    | Some data ->
        if is_inode data then begin
          let children = parse_inode data in
          let idx = bucket ~depth name in
          match children.(idx) with
          | None -> None
          | Some child -> find_at ~depth:(depth + 1) ~backend child name
        end else
          match F.node_of_bytes data with
          | Ok node -> F.find node name
          | Error _ -> None

  let find ~backend hash name = find_at ~depth:0 ~backend hash name

  (* --- List all entries --- *)

  let rec list_at ~(backend : hash Backend.t) hash =
    match backend.read hash with
    | None -> []
    | Some data ->
        if is_inode data then begin
          let children = parse_inode data in
          Array.to_list children
          |> List.filter_map Fun.id
          |> List.concat_map (list_at ~backend)
        end else
          match F.node_of_bytes data with
          | Ok node -> entries_of_node node
          | Error _ -> []

  let list_all ~backend hash = list_at ~backend hash

  (* --- Incremental update --- *)

  let rec update_at ~depth ~(backend : hash Backend.t) hash ~additions ~removals =
    match backend.read hash with
    | None ->
        (* Missing node: just write additions *)
        if additions = [] then hash
        else write_entries ~depth additions ~backend
    | Some data ->
        if is_inode data then
          update_inode ~depth ~backend data ~additions ~removals
        else
          update_flat ~depth ~backend data ~additions ~removals

  and update_inode ~depth ~(backend : hash Backend.t) data ~additions ~removals =
    let children = parse_inode data in
    (* Group additions and removals by bucket *)
    let adds = Array.make branching [] in
    let rems = Array.make branching [] in
    List.iter (fun ((name, _) as e) ->
        let idx = bucket ~depth name in
        adds.(idx) <- e :: adds.(idx))
      additions;
    List.iter (fun name ->
        let idx = bucket ~depth name in
        rems.(idx) <- name :: rems.(idx))
      removals;
    (* Update only affected buckets *)
    let changed = ref false in
    let new_children = Array.copy children in
    for i = 0 to branching - 1 do
      if adds.(i) <> [] || rems.(i) <> [] then begin
        changed := true;
        match children.(i) with
        | None ->
            if adds.(i) <> [] then
              new_children.(i) <-
                Some (write_entries ~depth:(depth + 1) adds.(i) ~backend)
        | Some child_hash ->
            let new_hash =
              update_at ~depth:(depth + 1) ~backend child_hash
                ~additions:adds.(i) ~removals:rems.(i)
            in
            new_children.(i) <- Some new_hash
      end
    done;
    if not !changed then
      hash_inode_data data
    else begin
      (* Check if we should demote back to flat *)
      let total =
        Array.fold_left (fun n c ->
            match c with None -> n | Some _ -> n + 1) 0 new_children
      in
      if total = 0 then
        write_flat [] ~backend
      else begin
        let new_data = serialize_inode new_children in
        let h = hash_inode_data new_data in
        backend.write h new_data;
        h
      end
    end

  and update_flat ~depth ~(backend : hash Backend.t) data ~additions ~removals =
    match F.node_of_bytes data with
    | Error _ -> write_entries ~depth additions ~backend
    | Ok node ->
        let node = List.fold_left (fun n name -> F.remove n name) node removals in
        let node =
          List.fold_left (fun n (name, entry) -> F.add n name entry) node additions
        in
        let entries = entries_of_node node in
        let count = List.length entries in
        if count > max_entries then
          write_entries ~depth entries ~backend
        else begin
          let new_data = F.bytes_of_node node in
          let h = F.hash_node node in
          backend.write h new_data;
          h
        end

  let update ~backend hash ~additions ~removals =
    update_at ~depth:0 ~backend hash ~additions ~removals
end
