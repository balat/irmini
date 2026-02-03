open Irmin

(* Hash tests *)
let test_sha1_hash () =
  let h = Hash.sha1 "hello" in
  let hex = Hash.to_hex h in
  Alcotest.(check string)
    "sha1 hex length" (String.make 40 '0')
    (String.make (String.length hex) '0');
  Alcotest.(check int) "sha1 bytes length" 20 (String.length (Hash.to_bytes h))

let test_sha256_hash () =
  let h = Hash.sha256 "hello" in
  let hex = Hash.to_hex h in
  Alcotest.(check string)
    "sha256 hex length" (String.make 64 '0')
    (String.make (String.length hex) '0');
  Alcotest.(check int)
    "sha256 bytes length" 32
    (String.length (Hash.to_bytes h))

let test_hash_roundtrip () =
  let h1 = Hash.sha1 "test data" in
  let hex = Hash.to_hex h1 in
  match Hash.sha1_of_hex hex with
  | Ok h2 -> Alcotest.(check bool) "roundtrip" true (Hash.equal h1 h2)
  | Error (`Msg msg) -> Alcotest.fail msg

let test_mst_depth () =
  (* Test MST depth calculation *)
  let h = Hash.sha256 "test" in
  let depth = Hash.mst_depth h in
  Alcotest.(check bool) "depth >= 0" true (depth >= 0)

(* Tree tests *)
let test_empty_tree () =
  let tree = Tree.Git.empty () in
  Alcotest.(check (option string))
    "find empty" None
    (Tree.Git.find tree [ "foo" ])

let test_tree_add_find () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "foo"; "bar" ] "content" in
  Alcotest.(check (option string))
    "find added" (Some "content")
    (Tree.Git.find tree [ "foo"; "bar" ])

let test_tree_remove () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "foo" ] "content" in
  let tree = Tree.Git.remove tree [ "foo" ] in
  Alcotest.(check (option string))
    "find removed" None
    (Tree.Git.find tree [ "foo" ])

let test_tree_overwrite () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "key" ] "value1" in
  let tree = Tree.Git.add tree [ "key" ] "value2" in
  Alcotest.(check (option string))
    "find overwritten" (Some "value2")
    (Tree.Git.find tree [ "key" ])

let test_tree_nested () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "a"; "b"; "c" ] "deep" in
  let tree = Tree.Git.add tree [ "a"; "x" ] "shallow" in
  Alcotest.(check (option string))
    "find deep" (Some "deep")
    (Tree.Git.find tree [ "a"; "b"; "c" ]);
  Alcotest.(check (option string))
    "find shallow" (Some "shallow")
    (Tree.Git.find tree [ "a"; "x" ])

(* Backend tests *)
let test_memory_backend () =
  let backend = Backend.Memory.create_sha1 () in
  let data = "test content" in
  let hash = Hash.sha1 data in
  backend.write hash data;
  Alcotest.(check (option string)) "read back" (Some data) (backend.read hash)

let test_backend_refs () =
  let backend = Backend.Memory.create_sha1 () in
  let data = "content" in
  let hash = Hash.sha1 data in
  backend.write hash data;
  backend.set_ref "refs/heads/main" hash;
  Alcotest.(check bool)
    "ref exists" true
    (Option.is_some (backend.get_ref "refs/heads/main"));
  match backend.get_ref "refs/heads/main" with
  | Some h -> Alcotest.(check bool) "ref matches" true (Hash.equal hash h)
  | None -> Alcotest.fail "ref not found"

let test_backend_test_and_set () =
  let backend = Backend.Memory.create_sha1 () in
  let h1 = Hash.sha1 "content1" in
  let h2 = Hash.sha1 "content2" in
  backend.write h1 "content1";
  backend.write h2 "content2";
  backend.set_ref "ref" h1;

  (* Should fail with wrong test value *)
  let result = backend.test_and_set_ref "ref" ~test:(Some h2) ~set:(Some h2) in
  Alcotest.(check bool) "wrong test fails" false result;

  (* Should succeed with correct test value *)
  let result = backend.test_and_set_ref "ref" ~test:(Some h1) ~set:(Some h2) in
  Alcotest.(check bool) "correct test succeeds" true result

(* Store tests *)
let test_store_commit () =
  let backend = Backend.Memory.create_sha1 () in
  let store = Store.Git.create ~backend in
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "README.md" ] "# Hello" in
  let hash =
    Store.Git.commit store ~tree ~parents:[] ~message:"Initial commit"
      ~author:"test"
  in
  Alcotest.(check bool) "commit hash exists" true (backend.exists hash)

let test_store_branches () =
  let backend = Backend.Memory.create_sha1 () in
  let store = Store.Git.create ~backend in
  let tree = Tree.Git.empty () in
  let hash =
    Store.Git.commit store ~tree ~parents:[] ~message:"test" ~author:"test"
  in
  Store.Git.set_head store ~branch:"main" hash;
  let branches = Store.Git.branches store in
  Alcotest.(check (list string)) "branches" [ "main" ] branches

(* Tree format tests *)
let test_git_tree_format () =
  let node = Codec.Git.empty_node in
  Alcotest.(check bool) "empty is empty" true (Codec.Git.is_empty node);
  let h = Hash.sha1 "content" in
  let node = Codec.Git.add node "file.txt" (`Contents h) in
  Alcotest.(check bool) "not empty after add" false (Codec.Git.is_empty node);
  match Codec.Git.find node "file.txt" with
  | Some (`Contents h') ->
      Alcotest.(check bool) "find matches" true (Hash.equal h h')
  | _ -> Alcotest.fail "entry not found"

let test_git_tree_serialization () =
  let h = Hash.sha1 "content" in
  let node = Codec.Git.empty_node in
  let node = Codec.Git.add node "file.txt" (`Contents h) in
  let bytes = Codec.Git.bytes_of_node node in
  match Codec.Git.node_of_bytes bytes with
  | Ok node' ->
      let entries = Codec.Git.list node' in
      Alcotest.(check int) "one entry" 1 (List.length entries)
  | Error (`Msg msg) -> Alcotest.fail msg

(* Test suites *)
let hash_tests =
  [
    Alcotest.test_case "sha1 hash" `Quick test_sha1_hash;
    Alcotest.test_case "sha256 hash" `Quick test_sha256_hash;
    Alcotest.test_case "hash roundtrip" `Quick test_hash_roundtrip;
    Alcotest.test_case "mst depth" `Quick test_mst_depth;
  ]

let tree_tests =
  [
    Alcotest.test_case "empty tree" `Quick test_empty_tree;
    Alcotest.test_case "tree add/find" `Quick test_tree_add_find;
    Alcotest.test_case "tree remove" `Quick test_tree_remove;
    Alcotest.test_case "tree overwrite" `Quick test_tree_overwrite;
    Alcotest.test_case "tree nested" `Quick test_tree_nested;
  ]

let backend_tests =
  [
    Alcotest.test_case "memory backend" `Quick test_memory_backend;
    Alcotest.test_case "backend refs" `Quick test_backend_refs;
    Alcotest.test_case "backend test_and_set" `Quick test_backend_test_and_set;
  ]

let store_tests =
  [
    Alcotest.test_case "store commit" `Quick test_store_commit;
    Alcotest.test_case "store branches" `Quick test_store_branches;
  ]

let tree_format_tests =
  [
    Alcotest.test_case "git tree format" `Quick test_git_tree_format;
    Alcotest.test_case "git tree serialization" `Quick
      test_git_tree_serialization;
  ]

(* Link tests *)
let test_link_v_get () =
  let s = Link.Mst.v () in
  let l = Link.v s 42 in
  Alcotest.(check int) "get (v s x) = x" 42 (Link.get l)

let test_link_is_val () =
  let s = Link.Mst.v () in
  let l = Link.v s "hello" in
  Alcotest.(check bool) "in-memory is_val" true (Link.is_val l)

let test_link_equal () =
  let s = Link.Mst.v () in
  let l0 = Link.v s [ 1; 2; 3 ] in
  let l1 = Link.v s [ 1; 2; 3 ] in
  let l2 = Link.v s [ 1; 2; 4 ] in
  Alcotest.(check bool) "same value equal" true (Link.equal l0 l1);
  Alcotest.(check bool) "diff value not equal" false (Link.equal l0 l2)

let test_link_address () =
  let s = Link.Mst.v () in
  let l0 = Link.v s "test" in
  let l1 = Link.v s "test" in
  Alcotest.(check bool) "same address" true (Link.address l0 = Link.address l1)

let test_link_pp () =
  let s = Link.Mst.v () in
  let l = Link.v s "test" in
  let _ = Link.address l in
  (* force address computation *)
  let str = Format.asprintf "%a" Link.pp l in
  Alcotest.(check int) "pp is 7 chars" 7 (String.length str)

let test_link_read_write () =
  let s : int Link.store = Link.Mst.v () in
  Link.write s 42;
  Alcotest.(check int) "after write" 42 (Link.read s);
  Link.write s 100;
  Alcotest.(check int) "after second write" 100 (Link.read s)

let test_link_is_open () =
  let s = Link.Mst.v () in
  Alcotest.(check bool) "initially open" true (Link.is_open s);
  Link.close s;
  Alcotest.(check bool) "closed after close" false (Link.is_open s)

(* Tree types for the tree example test *)
type test_tree = test_node Link.t
and test_node = TEmpty | TNode of { l : test_tree; x : int; r : test_tree }

let test_link_tree () =
  let s = Link.Mst.v () in
  let empty = Link.v s TEmpty in
  let leaf x = Link.v s (TNode { l = empty; x; r = empty }) in
  let node l x r = Link.v s (TNode { l; x; r }) in
  let t = node (leaf 1) 2 (leaf 3) in
  match Link.get t with
  | TEmpty -> Alcotest.fail "expected node"
  | TNode n -> (
      Alcotest.(check int) "root" 2 n.x;
      match (Link.get n.l, Link.get n.r) with
      | TNode l, TNode r ->
          Alcotest.(check int) "left" 1 l.x;
          Alcotest.(check int) "right" 3 r.x
      | _ -> Alcotest.fail "expected leaves")

let link_tests =
  [
    Alcotest.test_case "v/get" `Quick test_link_v_get;
    Alcotest.test_case "is_val" `Quick test_link_is_val;
    Alcotest.test_case "equal" `Quick test_link_equal;
    Alcotest.test_case "address" `Quick test_link_address;
    Alcotest.test_case "pp" `Quick test_link_pp;
    Alcotest.test_case "read/write" `Quick test_link_read_write;
    Alcotest.test_case "is_open" `Quick test_link_is_open;
    Alcotest.test_case "tree" `Quick test_link_tree;
  ]

(* Proof tests *)
let test_proof_produce_verify () =
  let backend = Backend.Memory.create_sha1 () in
  (* Build a tree: foo/bar = "hello", foo/baz = "world" *)
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "foo"; "bar" ] "hello" in
  let tree = Tree.Git.add tree [ "foo"; "baz" ] "world" in
  let root_hash = Tree.Git.hash tree ~backend in
  (* Produce a proof that only accesses foo/bar *)
  let proof, result =
    Proof.Git.produce backend root_hash (fun t ->
        let v = Proof.Git.Tree.find t [ "foo"; "bar" ] in
        (t, v))
  in
  Alcotest.(check (option string)) "found value" (Some "hello") result;
  (* Verify the proof *)
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
  (* Only access "a", "b" should be blinded *)
  let proof, _ =
    Proof.Git.produce backend root_hash (fun t ->
        let _ = Proof.Git.Tree.find t [ "a" ] in
        (t, ()))
  in
  (* Check proof state has blinded nodes *)
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

let proof_tests =
  [
    Alcotest.test_case "produce/verify" `Quick test_proof_produce_verify;
    Alcotest.test_case "blinded nodes" `Quick test_proof_blinded;
    Alcotest.test_case "mst proofs" `Quick test_proof_mst;
  ]

let () =
  Alcotest.run "Irmin"
    [
      ("Hash", hash_tests);
      ("Tree", tree_tests);
      ("Backend", backend_tests);
      ("Store", store_tests);
      ("Codec", tree_format_tests);
      ("Link", link_tests);
      ("Proof", proof_tests);
    ]
