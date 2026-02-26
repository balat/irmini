open Irmin

let test_proof_produce_verify () =
  let backend = Backend.Memory.create_sha1 () in
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "foo"; "bar" ] "hello" in
  let tree = Tree.Git.add tree [ "foo"; "baz" ] "world" in
  let root_hash = Tree.Git.hash tree ~backend in
  let proof, result =
    Proof.Git.produce backend root_hash (fun t ->
        let v = Proof.Git.Tree.find t [ "foo"; "bar" ] in
        (t, v))
  in
  Alcotest.(check (option string)) "found value" (Some "hello") result;
  match
    Proof.Git.verify proof (fun t ->
        let v = Proof.Git.Tree.find t [ "foo"; "bar" ] in
        (t, v))
  with
  | Ok (_, v) ->
      Alcotest.(check (option string)) "verified value" (Some "hello") v
  | Error (`Proof_mismatch msg) -> Alcotest.fail ("proof mismatch: " ^ msg)

let test_proof_blinded () =
  let backend = Backend.Memory.create_sha1 () in
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "a" ] "1" in
  let tree = Tree.Git.add tree [ "b" ] "2" in
  let root_hash = Tree.Git.hash tree ~backend in
  let proof, _ =
    Proof.Git.produce backend root_hash (fun t ->
        let _ = Proof.Git.Tree.find t [ "a" ] in
        (t, ()))
  in
  let state = Proof.state proof in
  match state with
  | Proof.Node entries ->
      let has_a =
        List.exists
          (fun (k, v) ->
            k = "a" && match v with Proof.Contents "1" -> true | _ -> false)
          entries
      in
      let has_blinded_b =
        List.exists
          (fun (k, v) ->
            k = "b"
            && match v with Proof.Blinded_contents _ -> true | _ -> false)
          entries
      in
      Alcotest.(check bool) "has a" true has_a;
      Alcotest.(check bool) "b is blinded" true has_blinded_b
  | _ -> Alcotest.fail "expected Node"

let test_proof_mst () =
  let backend = Backend.Memory.create_sha256 () in
  let tree = Tree.Mst.empty () in
  let tree = Tree.Mst.add tree [ "key1" ] "value1" in
  let tree = Tree.Mst.add tree [ "key2" ] "value2" in
  let root_hash = Tree.Mst.hash tree ~backend in
  let proof, result =
    Proof.Mst.produce backend root_hash (fun t ->
        let v = Proof.Mst.Tree.find t [ "key1" ] in
        (t, v))
  in
  Alcotest.(check (option string)) "found value" (Some "value1") result;
  match
    Proof.Mst.verify proof (fun t ->
        let v = Proof.Mst.Tree.find t [ "key1" ] in
        (t, v))
  with
  | Ok (_, v) ->
      Alcotest.(check (option string)) "verified value" (Some "value1") v
  | Error (`Proof_mismatch msg) -> Alcotest.fail ("proof mismatch: " ^ msg)

let suite =
  ( "Proof",
    [
      Alcotest.test_case "produce/verify" `Quick test_proof_produce_verify;
      Alcotest.test_case "blinded nodes" `Quick test_proof_blinded;
      Alcotest.test_case "mst proofs" `Quick test_proof_mst;
    ] )
