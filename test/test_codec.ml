open Irmin

(* ================================================================== *)
(* Git codec tests                                                     *)
(* ================================================================== *)

let test_git_empty_node () =
  let node = Codec.Git.empty_node in
  Alcotest.(check bool) "empty" true (Codec.Git.is_empty node);
  Alcotest.(check int) "list" 0 (List.length (Codec.Git.list node))

let test_git_add_find () =
  let h = Hash.sha1 "content" in
  let node = Codec.Git.add Codec.Git.empty_node "file.txt" (`Contents h) in
  Alcotest.(check bool) "not empty" false (Codec.Git.is_empty node);
  match Codec.Git.find node "file.txt" with
  | Some (`Contents h') ->
      Alcotest.(check bool) "hash match" true (Hash.equal h h')
  | _ -> Alcotest.fail "entry not found"

let test_git_add_node_entry () =
  let h = Hash.sha1 "tree-data" in
  let node = Codec.Git.add Codec.Git.empty_node "subdir" (`Node h) in
  match Codec.Git.find node "subdir" with
  | Some (`Node h') ->
      Alcotest.(check bool) "node hash" true (Hash.equal h h')
  | _ -> Alcotest.fail "node entry not found"

let test_git_remove () =
  let h = Hash.sha1 "content" in
  let node = Codec.Git.add Codec.Git.empty_node "a" (`Contents h) in
  let node = Codec.Git.add node "b" (`Contents h) in
  let node = Codec.Git.remove node "a" in
  Alcotest.(check bool) "a removed" true (Option.is_none (Codec.Git.find node "a"));
  Alcotest.(check bool) "b kept" true (Option.is_some (Codec.Git.find node "b"))

let test_git_list_sorted () =
  let h = Hash.sha1 "v" in
  let node = Codec.Git.empty_node in
  let node = Codec.Git.add node "c" (`Contents h) in
  let node = Codec.Git.add node "a" (`Contents h) in
  let node = Codec.Git.add node "b" (`Contents h) in
  let names = List.map fst (Codec.Git.list node) in
  Alcotest.(check (list string)) "sorted" ["a"; "b"; "c"] names

let test_git_overwrite () =
  let h1 = Hash.sha1 "v1" in
  let h2 = Hash.sha1 "v2" in
  let node = Codec.Git.add Codec.Git.empty_node "f" (`Contents h1) in
  let node = Codec.Git.add node "f" (`Contents h2) in
  match Codec.Git.find node "f" with
  | Some (`Contents h') ->
      Alcotest.(check bool) "updated" true (Hash.equal h2 h')
  | _ -> Alcotest.fail "overwrite failed"

let test_git_serialization_roundtrip () =
  let h1 = Hash.sha1 "content1" in
  let h2 = Hash.sha1 "content2" in
  let h3 = Hash.sha1 "tree" in
  let node = Codec.Git.empty_node in
  let node = Codec.Git.add node "file1.txt" (`Contents h1) in
  let node = Codec.Git.add node "file2.txt" (`Contents h2) in
  let node = Codec.Git.add node "subdir" (`Node h3) in
  let bytes = Codec.Git.bytes_of_node node in
  match Codec.Git.node_of_bytes bytes with
  | Ok node' ->
      let entries = Codec.Git.list node' in
      Alcotest.(check int) "3 entries" 3 (List.length entries);
      Alcotest.(check bool) "file1" true
        (Option.is_some (Codec.Git.find node' "file1.txt"));
      Alcotest.(check bool) "subdir" true
        (Option.is_some (Codec.Git.find node' "subdir"))
  | Error (`Msg msg) -> Alcotest.fail msg

let test_git_hash_deterministic () =
  let h = Hash.sha1 "content" in
  let node1 = Codec.Git.add Codec.Git.empty_node "f" (`Contents h) in
  let node2 = Codec.Git.add Codec.Git.empty_node "f" (`Contents h) in
  Alcotest.(check string) "same hash"
    (Codec.Git.hash_to_hex (Codec.Git.hash_node node1))
    (Codec.Git.hash_to_hex (Codec.Git.hash_node node2))

let test_git_inlining () =
  let short = "small" in (* 5 bytes < 48 threshold *)
  let long = String.make 100 'x' in (* 100 bytes > 48 threshold *)
  let node = Codec.Git.empty_node in
  let node = Codec.Git.add node "small" (`Contents_inlined short) in
  let node = Codec.Git.add node "large" (`Contents (Hash.sha1 long)) in
  let bytes = Codec.Git.bytes_of_node node in
  match Codec.Git.node_of_bytes bytes with
  | Ok node' ->
      (match Codec.Git.find node' "small" with
       | Some (`Contents_inlined v) ->
           Alcotest.(check string) "inlined value" short v
       | _ -> Alcotest.fail "inlined entry not found");
      Alcotest.(check bool) "large" true
        (Option.is_some (Codec.Git.find node' "large"))
  | Error (`Msg msg) -> Alcotest.fail msg

let test_git_commit_roundtrip () =
  let tree = Hash.sha1 "tree" in
  let parent = Hash.sha1 "parent" in
  let c = Codec.Git.commit_make ~tree ~parents:[parent]
      ~author:"test" ~committer:"test" ~message:"msg" ~timestamp:0L in
  let bytes = Codec.Git.commit_to_bytes c in
  match Codec.Git.commit_of_bytes bytes with
  | Ok c' ->
      Alcotest.(check string) "author" "test" (Codec.Git.commit_author c');
      Alcotest.(check string) "message" "msg" (Codec.Git.commit_message c');
      Alcotest.(check int) "parents" 1
        (List.length (Codec.Git.commit_parents c'))
  | Error (`Msg msg) -> Alcotest.fail msg

let test_git_hash_hex_roundtrip () =
  let h = Hash.sha1 "test" in
  let hex = Codec.Git.hash_to_hex h in
  match Codec.Git.hash_of_hex hex with
  | Ok h' ->
      Alcotest.(check string) "roundtrip"
        (Codec.Git.hash_to_hex h) (Codec.Git.hash_to_hex h')
  | Error (`Msg msg) -> Alcotest.fail msg

(* ================================================================== *)
(* MST codec tests                                                     *)
(* ================================================================== *)

let test_mst_empty_node () =
  let node = Codec.Mst.empty_node in
  Alcotest.(check bool) "empty" true (Codec.Mst.is_empty node);
  Alcotest.(check int) "list" 0 (List.length (Codec.Mst.list node))

let test_mst_add_find () =
  let h = Hash.sha256 "content" in
  let node = Codec.Mst.add Codec.Mst.empty_node "key1" (`Contents h) in
  match Codec.Mst.find node "key1" with
  | Some (`Contents h') ->
      Alcotest.(check bool) "hash match" true (Hash.equal h h')
  | _ -> Alcotest.fail "entry not found"

let test_mst_multiple_entries () =
  let node = Codec.Mst.empty_node in
  let node = Codec.Mst.add node "alice" (`Contents (Hash.sha256 "a")) in
  let node = Codec.Mst.add node "bob" (`Contents (Hash.sha256 "b")) in
  let node = Codec.Mst.add node "carol" (`Contents (Hash.sha256 "c")) in
  let entries = Codec.Mst.list node in
  Alcotest.(check int) "3 entries" 3 (List.length entries);
  let names = List.map fst entries in
  (* MST entries should be sorted by key *)
  Alcotest.(check (list string)) "sorted" ["alice"; "bob"; "carol"] names

let test_mst_remove () =
  let h = Hash.sha256 "v" in
  let node = Codec.Mst.add Codec.Mst.empty_node "a" (`Contents h) in
  let node = Codec.Mst.add node "b" (`Contents h) in
  let node = Codec.Mst.remove node "a" in
  Alcotest.(check bool) "a removed" true
    (Option.is_none (Codec.Mst.find node "a"));
  Alcotest.(check bool) "b kept" true
    (Option.is_some (Codec.Mst.find node "b"))

let test_mst_serialization_roundtrip () =
  let h1 = Hash.sha256 "val1" in
  let h2 = Hash.sha256 "val2" in
  let node = Codec.Mst.empty_node in
  let node = Codec.Mst.add node "key1" (`Contents h1) in
  let node = Codec.Mst.add node "key2" (`Contents h2) in
  let bytes = Codec.Mst.bytes_of_node node in
  match Codec.Mst.node_of_bytes bytes with
  | Ok node' ->
      let entries = Codec.Mst.list node' in
      Alcotest.(check int) "2 entries" 2 (List.length entries);
      Alcotest.(check bool) "key1" true
        (Option.is_some (Codec.Mst.find node' "key1"));
      Alcotest.(check bool) "key2" true
        (Option.is_some (Codec.Mst.find node' "key2"))
  | Error (`Msg msg) -> Alcotest.fail msg

let test_mst_hash_deterministic () =
  let h = Hash.sha256 "content" in
  let node1 = Codec.Mst.add Codec.Mst.empty_node "k" (`Contents h) in
  let node2 = Codec.Mst.add Codec.Mst.empty_node "k" (`Contents h) in
  Alcotest.(check string) "same hash"
    (Codec.Mst.hash_to_hex (Codec.Mst.hash_node node1))
    (Codec.Mst.hash_to_hex (Codec.Mst.hash_node node2))

let test_mst_commit_roundtrip () =
  let tree = Hash.sha256 "tree" in
  let c = Codec.Mst.commit_make ~tree ~parents:[]
      ~author:"test" ~committer:"test" ~message:"hello" ~timestamp:1000L in
  let bytes = Codec.Mst.commit_to_bytes c in
  match Codec.Mst.commit_of_bytes bytes with
  | Ok c' ->
      Alcotest.(check string) "author" "test" (Codec.Mst.commit_author c');
      Alcotest.(check string) "message" "hello" (Codec.Mst.commit_message c');
      Alcotest.(check int) "no parents" 0
        (List.length (Codec.Mst.commit_parents c'))
  | Error (`Msg msg) -> Alcotest.fail msg

let test_mst_hash_hex_roundtrip () =
  let h = Hash.sha256 "test" in
  let hex = Codec.Mst.hash_to_hex h in
  match Codec.Mst.hash_of_hex hex with
  | Ok h' ->
      Alcotest.(check string) "roundtrip"
        (Codec.Mst.hash_to_hex h) (Codec.Mst.hash_to_hex h')
  | Error (`Msg msg) -> Alcotest.fail msg

let suite =
  ( "Codec",
    [
      (* Git codec *)
      Alcotest.test_case "git: empty node" `Quick test_git_empty_node;
      Alcotest.test_case "git: add/find" `Quick test_git_add_find;
      Alcotest.test_case "git: add node entry" `Quick test_git_add_node_entry;
      Alcotest.test_case "git: remove" `Quick test_git_remove;
      Alcotest.test_case "git: list sorted" `Quick test_git_list_sorted;
      Alcotest.test_case "git: overwrite" `Quick test_git_overwrite;
      Alcotest.test_case "git: serialization roundtrip" `Quick test_git_serialization_roundtrip;
      Alcotest.test_case "git: hash deterministic" `Quick test_git_hash_deterministic;
      Alcotest.test_case "git: inlining" `Quick test_git_inlining;
      Alcotest.test_case "git: commit roundtrip" `Quick test_git_commit_roundtrip;
      Alcotest.test_case "git: hash hex roundtrip" `Quick test_git_hash_hex_roundtrip;
      (* MST codec *)
      Alcotest.test_case "mst: empty node" `Quick test_mst_empty_node;
      Alcotest.test_case "mst: add/find" `Quick test_mst_add_find;
      Alcotest.test_case "mst: multiple entries" `Quick test_mst_multiple_entries;
      Alcotest.test_case "mst: remove" `Quick test_mst_remove;
      Alcotest.test_case "mst: serialization roundtrip" `Quick test_mst_serialization_roundtrip;
      Alcotest.test_case "mst: hash deterministic" `Quick test_mst_hash_deterministic;
      Alcotest.test_case "mst: commit roundtrip" `Quick test_mst_commit_roundtrip;
      Alcotest.test_case "mst: hash hex roundtrip" `Quick test_mst_hash_hex_roundtrip;
    ] )
