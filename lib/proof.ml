(** Merkle proofs for content-addressed trees. *)

type 'hash kinded_hash = [ `Contents of 'hash | `Node of 'hash ]

type ('hash, 'contents) tree =
  | Contents of 'contents
  | Blinded_contents of 'hash
  | Node of ('hash, 'contents) node
  | Blinded_node of 'hash

and ('hash, 'contents) node = (string * ('hash, 'contents) tree) list

type ('hash, 'contents) t = {
  before : 'hash kinded_hash;
  after : 'hash kinded_hash;
  state : ('hash, 'contents) tree;
}

let v ~before ~after state = { before; after; state }
let before p = p.before
let after p = p.after
let state p = p.state

module Make (C : Codec.S) = struct
  type hash = C.hash
  type contents = string

  (* Path set for tracking accessed paths *)
  module PathSet = Set.Make (struct
    type t = string list

    let compare = compare
  end)

  (* Internal tree representation during proof production *)
  type tree_state =
    | Producing of {
        backend : hash Backend.t;
        node_hash : hash;
        mutable accessed : PathSet.t;
      }
    | From_proof of { tree : (hash, contents) tree }

  module Tree = struct
    type t = { state : tree_state }

    let of_hash backend h =
      { state = Producing { backend; node_hash = h; accessed = PathSet.empty } }

    let of_proof_tree tree = { state = From_proof { tree } }

    (* Read node from backend *)
    let read_node backend h =
      match backend.Backend.read h with
      | None -> None
      | Some data -> (
          match C.node_of_bytes data with Ok n -> Some n | Error _ -> None)

    (* Read contents from backend *)
    let read_contents backend h = backend.Backend.read h

    (* Record access to a path *)
    let record_access t path =
      match t.state with
      | Producing p -> p.accessed <- PathSet.add path p.accessed
      | From_proof _ -> ()

    (* Navigate to a path in a backend-stored node *)
    let rec find_in_node backend node path =
      match path with
      | [] -> None (* Can't find contents at node root *)
      | [ key ] -> (
          match C.find node key with
          | Some (`Contents h) -> read_contents backend h
          | _ -> None)
      | key :: rest -> (
          match C.find node key with
          | Some (`Node h) -> (
              match read_node backend h with
              | Some child -> find_in_node backend child rest
              | None -> None)
          | _ -> None)

    (* Navigate in proof tree *)
    let rec find_in_proof tree path =
      match (tree, path) with
      | Contents c, [] -> Some c
      | Node entries, key :: rest -> (
          match List.assoc_opt key entries with
          | Some child -> find_in_proof child rest
          | None -> None)
      | Blinded_contents _, [] -> None (* Can't read blinded *)
      | Blinded_node _, _ -> None (* Can't traverse blinded *)
      | _ -> None

    let find t path =
      record_access t path;
      match t.state with
      | Producing { backend; node_hash; _ } -> (
          match read_node backend node_hash with
          | Some node -> find_in_node backend node path
          | None -> None)
      | From_proof { tree } -> find_in_proof tree path

    let rec find_tree_in_node backend node path =
      match path with
      | [] -> Some (of_hash backend (C.hash_node node))
      | key :: rest -> (
          match C.find node key with
          | Some (`Node h) -> (
              match read_node backend h with
              | Some child -> find_tree_in_node backend child rest
              | None -> None)
          | Some (`Contents _) -> None
          | None -> None)

    let rec find_tree_in_proof tree path =
      match (tree, path) with
      | (Node _ as n), [] -> Some (of_proof_tree n)
      | Node entries, key :: rest -> (
          match List.assoc_opt key entries with
          | Some child -> find_tree_in_proof child rest
          | None -> None)
      | Blinded_node _, _ -> None
      | Contents _, _ | Blinded_contents _, _ -> None

    let find_tree t path =
      record_access t path;
      match t.state with
      | Producing { backend; node_hash; _ } -> (
          match read_node backend node_hash with
          | Some node -> find_tree_in_node backend node path
          | None -> None)
      | From_proof { tree } -> find_tree_in_proof tree path

    let mem t path = Option.is_some (find t path)

    let list t path =
      record_access t path;
      match t.state with
      | Producing { backend; node_hash; _ } -> (
          let rec navigate node = function
            | [] ->
                C.list node
                |> List.map (fun (k, v) ->
                    let kind =
                      match v with `Node _ -> `Node | `Contents _ -> `Contents
                    in
                    (k, kind))
            | key :: rest -> (
                match C.find node key with
                | Some (`Node h) -> (
                    match read_node backend h with
                    | Some child -> navigate child rest
                    | None -> [])
                | _ -> [])
          in
          match read_node backend node_hash with
          | Some node -> navigate node path
          | None -> [])
      | From_proof { tree } ->
          let rec navigate t = function
            | [] -> (
                match t with
                | Node entries ->
                    List.map
                      (fun (k, v) ->
                        let kind =
                          match v with
                          | Node _ | Blinded_node _ -> `Node
                          | Contents _ | Blinded_contents _ -> `Contents
                        in
                        (k, kind))
                      entries
                | _ -> [])
            | key :: rest -> (
                match t with
                | Node entries -> (
                    match List.assoc_opt key entries with
                    | Some child -> navigate child rest
                    | None -> [])
                | _ -> [])
          in
          navigate tree path

    (* Write operations - only work on producing trees *)
    let add t path contents =
      record_access t path;
      match t.state with
      | Producing { backend; node_hash; accessed } ->
          let rec add_to_node node = function
            | [] -> failwith "Proof.Tree.add: empty path"
            | [ key ] ->
                let h = C.hash_contents contents in
                backend.write h contents;
                C.add node key (`Contents h)
            | key :: rest ->
                let child_node =
                  match C.find node key with
                  | Some (`Node h) -> (
                      match read_node backend h with
                      | Some n -> n
                      | None -> C.empty_node)
                  | _ -> C.empty_node
                in
                let updated = add_to_node child_node rest in
                let data = C.bytes_of_node updated in
                let h = C.hash_node updated in
                backend.write h data;
                C.add node key (`Node h)
          in
          let node =
            match read_node backend node_hash with
            | Some n -> n
            | None -> C.empty_node
          in
          let updated = add_to_node node path in
          let data = C.bytes_of_node updated in
          let new_hash = C.hash_node updated in
          backend.write new_hash data;
          { state = Producing { backend; node_hash = new_hash; accessed } }
      | From_proof _ -> failwith "Proof.Tree.add: cannot modify proof tree"

    let add_tree t path child =
      record_access t path;
      match (t.state, child.state) with
      | ( Producing { backend; node_hash; accessed },
          Producing { node_hash = child_hash; _ } ) ->
          let rec add_tree_to_node node = function
            | [] -> failwith "Proof.Tree.add_tree: empty path"
            | [ key ] -> C.add node key (`Node child_hash)
            | key :: rest ->
                let sub_node =
                  match C.find node key with
                  | Some (`Node h) -> (
                      match read_node backend h with
                      | Some n -> n
                      | None -> C.empty_node)
                  | _ -> C.empty_node
                in
                let updated = add_tree_to_node sub_node rest in
                let data = C.bytes_of_node updated in
                let h = C.hash_node updated in
                backend.write h data;
                C.add node key (`Node h)
          in
          let node =
            match read_node backend node_hash with
            | Some n -> n
            | None -> C.empty_node
          in
          let updated = add_tree_to_node node path in
          let data = C.bytes_of_node updated in
          let new_hash = C.hash_node updated in
          backend.write new_hash data;
          { state = Producing { backend; node_hash = new_hash; accessed } }
      | _ -> failwith "Proof.Tree.add_tree: incompatible trees"

    let remove t path =
      record_access t path;
      match t.state with
      | Producing { backend; node_hash; accessed } ->
          let rec remove_from_node node = function
            | [] -> node
            | [ key ] -> C.remove node key
            | key :: rest -> (
                match C.find node key with
                | Some (`Node h) -> (
                    match read_node backend h with
                    | Some child ->
                        let updated = remove_from_node child rest in
                        if C.is_empty updated then C.remove node key
                        else
                          let data = C.bytes_of_node updated in
                          let h = C.hash_node updated in
                          backend.write h data;
                          C.add node key (`Node h)
                    | None -> node)
                | _ -> node)
          in
          let node =
            match read_node backend node_hash with
            | Some n -> n
            | None -> C.empty_node
          in
          let updated = remove_from_node node path in
          let data = C.bytes_of_node updated in
          let new_hash = C.hash_node updated in
          backend.write new_hash data;
          { state = Producing { backend; node_hash = new_hash; accessed } }
      | From_proof _ -> failwith "Proof.Tree.remove: cannot modify proof tree"

    let hash t =
      match t.state with
      | Producing { node_hash; _ } -> node_hash
      | From_proof { tree } ->
          let rec hash_tree = function
            | Contents c -> C.hash_contents c
            | Blinded_contents h -> h
            | Node entries ->
                let node =
                  List.fold_left
                    (fun n (k, v) ->
                      let kind =
                        match v with
                        | Node _ | Blinded_node _ -> `Node (hash_tree v)
                        | Contents _ | Blinded_contents _ ->
                            `Contents (hash_tree v)
                      in
                      C.add n k kind)
                    C.empty_node entries
                in
                C.hash_node node
            | Blinded_node h -> h
          in
          hash_tree tree
  end

  (* Build proof tree from accessed paths *)
  let build_proof_tree backend node_hash accessed =
    let rec build node prefix =
      let dominated_by_access =
        PathSet.exists
          (fun path ->
            let plen = List.length prefix in
            List.length path >= plen
            && List.filteri (fun i _ -> i < plen) path = prefix)
          accessed
      in
      if not dominated_by_access then Blinded_node (C.hash_node node)
      else
        let entries = C.list node in
        let children =
          List.map
            (fun (key, kind) ->
              let child_path = prefix @ [ key ] in
              let child_tree =
                match kind with
                | `Contents h ->
                    if PathSet.mem child_path accessed then
                      match backend.Backend.read h with
                      | Some c -> Contents c
                      | None -> Blinded_contents h
                    else Blinded_contents h
                | `Node h ->
                    if
                      PathSet.exists
                        (fun p ->
                          let clen = List.length child_path in
                          List.length p >= clen
                          && List.filteri (fun i _ -> i < clen) p = child_path)
                        accessed
                    then
                      match backend.Backend.read h with
                      | Some data -> (
                          match C.node_of_bytes data with
                          | Ok child_node -> build child_node child_path
                          | Error _ -> Blinded_node h)
                      | None -> Blinded_node h
                    else Blinded_node h
              in
              (key, child_tree))
            entries
        in
        Node children
    in
    match backend.Backend.read node_hash with
    | Some data -> (
        match C.node_of_bytes data with
        | Ok node -> build node []
        | Error _ -> Blinded_node node_hash)
    | None -> Blinded_node node_hash

  let produce backend root_hash f =
    let tree = Tree.of_hash backend root_hash in
    let result_tree, result = f tree in
    let after_hash = Tree.hash result_tree in
    let accessed =
      match tree.state with
      | Producing { accessed; _ } -> accessed
      | From_proof _ -> PathSet.empty
    in
    let proof_tree = build_proof_tree backend root_hash accessed in
    let proof =
      { before = `Node root_hash; after = `Node after_hash; state = proof_tree }
    in
    (proof, result)

  let to_tree proof = Tree.of_proof_tree proof.state

  let rec hash_of_tree = function
    | Contents c -> `Contents (C.hash_contents c)
    | Blinded_contents h -> `Contents h
    | Node entries ->
        let node =
          List.fold_left
            (fun n (k, v) ->
              let h =
                match hash_of_tree v with
                | `Contents h -> `Contents h
                | `Node h -> `Node h
              in
              C.add n k h)
            C.empty_node entries
        in
        `Node (C.hash_node node)
    | Blinded_node h -> `Node h

  let verify proof f =
    let tree = to_tree proof in
    let result_tree, result = f tree in
    let computed_after = `Node (Tree.hash result_tree) in
    let expected_after = proof.after in
    match (computed_after, expected_after) with
    | `Node h1, `Node h2 when C.hash_equal h1 h2 -> Ok (result_tree, result)
    | `Contents h1, `Contents h2 when C.hash_equal h1 h2 ->
        Ok (result_tree, result)
    | _ ->
        Error
          (`Proof_mismatch
             (Printf.sprintf "expected %s, got %s"
                (C.hash_to_hex
                   (match expected_after with `Node h | `Contents h -> h))
                (C.hash_to_hex
                   (match computed_after with `Node h | `Contents h -> h))))
end

module Git = Make (Codec.Git)
module Mst = Make (Codec.Mst)
