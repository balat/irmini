open Irmin

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

let test_store_diff () =
  let backend = Backend.Memory.create_sha1 () in
  let store = Store.Git.create ~backend in
  let tree1 = Tree.Git.empty () in
  let tree1 = Tree.Git.add tree1 [ "file1.txt" ] "content1" in
  let tree1 = Tree.Git.add tree1 [ "file2.txt" ] "content2" in
  let hash1 = Tree.Git.hash tree1 ~backend in
  let tree2 = Tree.Git.empty () in
  let tree2 = Tree.Git.add tree2 [ "file1.txt" ] "modified1" in
  let tree2 = Tree.Git.add tree2 [ "file3.txt" ] "content3" in
  let hash2 = Tree.Git.hash tree2 ~backend in
  let changes = Store.Git.diff store ~old:hash1 ~new_:hash2 |> List.of_seq in
  let has_remove_file2 =
    List.exists
      (function `Remove [ "file2.txt" ] -> true | _ -> false)
      changes
  in
  let has_add_file3 =
    List.exists
      (function `Add ([ "file3.txt" ], _) -> true | _ -> false)
      changes
  in
  let has_change_file1 =
    List.exists
      (function `Change ([ "file1.txt" ], _, _) -> true | _ -> false)
      changes
  in
  Alcotest.(check bool) "file2 removed" true has_remove_file2;
  Alcotest.(check bool) "file3 added" true has_add_file3;
  Alcotest.(check bool) "file1 changed" true has_change_file1

let suite =
  ( "Store",
    [
      Alcotest.test_case "store commit" `Quick test_store_commit;
      Alcotest.test_case "store branches" `Quick test_store_branches;
      Alcotest.test_case "store diff" `Quick test_store_diff;
    ] )
