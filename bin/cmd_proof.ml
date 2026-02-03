(** MST Proof commands. *)

open Irmin

let produce ~output ~key data =
  let backend = Backend.Memory.create_sha256 () in
  (* Parse input: lines of "key=value" *)
  let tree =
    List.fold_left
      (fun tree line ->
        match String.index_opt line '=' with
        | None -> tree
        | Some i ->
            let k = String.sub line 0 i in
            let v = String.sub line (i + 1) (String.length line - i - 1) in
            Tree.Mst.add tree [ k ] v)
      (Tree.Mst.empty ()) data
  in
  let root = Tree.Mst.hash tree ~backend in

  let path = [ key ] in
  let proof, result =
    Proof.Mst.produce backend root (fun t ->
        let v = Proof.Mst.Tree.find t path in
        (t, v))
  in

  let hash_str h = String.sub (Hash.to_hex h) 0 16 in
  let before_hash =
    match Proof.before proof with
    | `Node h -> hash_str h
    | `Contents h -> hash_str h
  in
  let after_hash =
    match Proof.after proof with
    | `Node h -> hash_str h
    | `Contents h -> hash_str h
  in

  (match output with
  | `Human ->
      Fmt.pr "Root:  %s@." (hash_str root);
      Fmt.pr "Key:   %s@." key;
      Fmt.pr "Value: %s@." (Option.value ~default:"<not found>" result);
      Fmt.pr "Before: %s@." before_hash;
      Fmt.pr "After:  %s@." after_hash
  | `Json ->
      Fmt.pr {|{"root":%S,"key":%S,"value":%s,"before":%S,"after":%S}@.|}
        (Hash.to_hex root) key
        (match result with Some v -> Printf.sprintf "%S" v | None -> "null")
        before_hash after_hash);
  0

let verify ~output ~key data =
  let backend = Backend.Memory.create_sha256 () in
  let tree =
    List.fold_left
      (fun tree line ->
        match String.index_opt line '=' with
        | None -> tree
        | Some i ->
            let k = String.sub line 0 i in
            let v = String.sub line (i + 1) (String.length line - i - 1) in
            Tree.Mst.add tree [ k ] v)
      (Tree.Mst.empty ()) data
  in
  let root = Tree.Mst.hash tree ~backend in

  let path = [ key ] in
  let proof, _ =
    Proof.Mst.produce backend root (fun t ->
        let v = Proof.Mst.Tree.find t path in
        (t, v))
  in

  match
    Proof.Mst.verify proof (fun t ->
        let v = Proof.Mst.Tree.find t path in
        (t, v))
  with
  | Ok (_, v) ->
      (match output with
      | `Human ->
          Common.success "Verified: %s" (Option.value ~default:"<none>" v)
      | `Json ->
          Fmt.pr {|{"verified":true,"value":%s}@.|}
            (match v with Some x -> Printf.sprintf "%S" x | None -> "null"));
      0
  | Error (`Proof_mismatch msg) ->
      (match output with
      | `Human -> Common.error "Invalid: %s" msg
      | `Json -> Fmt.pr {|{"verified":false,"error":%S}@.|} msg);
      1
