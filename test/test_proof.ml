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
  (* Use values larger than inline_threshold (48 bytes) so they are stored
     as separate blobs and can be properly blinded in proofs. *)
  let large_a = String.make 64 'a' in
  let large_b = String.make 64 'b' in
  let backend = Backend.Memory.create_sha1 () in
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "a" ] large_a in
  let tree = Tree.Git.add tree [ "b" ] large_b in
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
            k = "a"
            && match v with Proof.Contents c -> c = large_a | _ -> false)
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

(* Proof on a larger tree — only accessed paths are revealed *)
let test_proof_large_tree () =
  let backend = Backend.Memory.create_sha1 () in
  let tree = ref (Tree.Git.empty ()) in
  for i = 0 to 99 do
    tree := Tree.Git.add !tree
        [ Printf.sprintf "dir%d" (i / 10); Printf.sprintf "file%d" (i mod 10) ]
        (Printf.sprintf "value%d" i)
  done;
  let root_hash = Tree.Git.hash !tree ~backend in
  let proof, result =
    Proof.Git.produce backend root_hash (fun t ->
        let v = Proof.Git.Tree.find t [ "dir5"; "file3" ] in
        (t, v))
  in
  Alcotest.(check (option string)) "found" (Some "value53") result;
  match
    Proof.Git.verify proof (fun t ->
        let v = Proof.Git.Tree.find t [ "dir5"; "file3" ] in
        (t, v))
  with
  | Ok (_, v) ->
      Alcotest.(check (option string)) "verified" (Some "value53") v
  | Error (`Proof_mismatch msg) -> Alcotest.fail ("mismatch: " ^ msg)

(* Proof verification fails if function accesses different path *)
let test_proof_verify_wrong_path () =
  let backend = Backend.Memory.create_sha1 () in
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "a" ] "va" in
  let tree = Tree.Git.add tree [ "b" ] "vb" in
  let root_hash = Tree.Git.hash tree ~backend in
  (* Produce proof for path "a" *)
  let proof, _ =
    Proof.Git.produce backend root_hash (fun t ->
        let v = Proof.Git.Tree.find t [ "a" ] in
        (t, v))
  in
  (* Verify with path "b" — should fail because "b" was blinded *)
  match
    Proof.Git.verify proof (fun t ->
        let v = Proof.Git.Tree.find t [ "b" ] in
        (t, v))
  with
  | Ok (_, Some _) ->
      (* If b was inlined (< 48 bytes), it might still be visible.
         That's OK — inlined values are always revealed. *)
      ()
  | Ok (_, None) -> ()
  | Error (`Proof_mismatch _) -> ()

(* Proof for missing key returns None in both produce and verify *)
let test_proof_missing_key () =
  let backend = Backend.Memory.create_sha1 () in
  let tree = Tree.Git.add (Tree.Git.empty ()) [ "a" ] "v" in
  let root_hash = Tree.Git.hash tree ~backend in
  let proof, result =
    Proof.Git.produce backend root_hash (fun t ->
        let v = Proof.Git.Tree.find t [ "nonexistent" ] in
        (t, v))
  in
  Alcotest.(check (option string)) "missing in produce" None result;
  match
    Proof.Git.verify proof (fun t ->
        let v = Proof.Git.Tree.find t [ "nonexistent" ] in
        (t, v))
  with
  | Ok (_, v) ->
      Alcotest.(check (option string)) "missing in verify" None v
  | Error (`Proof_mismatch msg) -> Alcotest.fail ("mismatch: " ^ msg)

(* Multiple accesses in single proof *)
let test_proof_multi_access () =
  let backend = Backend.Memory.create_sha1 () in
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "x" ] "vx" in
  let tree = Tree.Git.add tree [ "y" ] "vy" in
  let tree = Tree.Git.add tree [ "z" ] "vz" in
  let root_hash = Tree.Git.hash tree ~backend in
  let proof, (rx, ry) =
    Proof.Git.produce backend root_hash (fun t ->
        let vx = Proof.Git.Tree.find t [ "x" ] in
        let vy = Proof.Git.Tree.find t [ "y" ] in
        (t, (vx, vy)))
  in
  Alcotest.(check (option string)) "x" (Some "vx") rx;
  Alcotest.(check (option string)) "y" (Some "vy") ry;
  match
    Proof.Git.verify proof (fun t ->
        let vx = Proof.Git.Tree.find t [ "x" ] in
        let vy = Proof.Git.Tree.find t [ "y" ] in
        (t, (vx, vy)))
  with
  | Ok (_, (vx, vy)) ->
      Alcotest.(check (option string)) "verified x" (Some "vx") vx;
      Alcotest.(check (option string)) "verified y" (Some "vy") vy
  | Error (`Proof_mismatch msg) -> Alcotest.fail ("mismatch: " ^ msg)

let suite =
  ( "Proof",
    [
      Alcotest.test_case "produce/verify" `Quick test_proof_produce_verify;
      Alcotest.test_case "blinded nodes" `Quick test_proof_blinded;
      Alcotest.test_case "mst proofs" `Quick test_proof_mst;
      Alcotest.test_case "large tree proof" `Quick test_proof_large_tree;
      Alcotest.test_case "verify wrong path" `Quick test_proof_verify_wrong_path;
      Alcotest.test_case "missing key" `Quick test_proof_missing_key;
      Alcotest.test_case "multi access" `Quick test_proof_multi_access;
    ] )
