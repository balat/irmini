open Irmin

let mk () =
  let backend = Backend.Memory.create_sha1 () in
  let store = Store.Git.create ~backend () in
  (store, backend)

(* ================================================================== *)
(* Basic tests (existing)                                              *)
(* ================================================================== *)

let test_store_commit () =
  let store, backend = mk () in
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "README.md" ] "# Hello" in
  let hash =
    Store.Git.commit store ~tree ~parents:[] ~message:"Initial commit"
      ~author:"test"
  in
  Alcotest.(check bool) "commit hash exists" true (backend.exists hash)

let test_store_branches () =
  let store, _ = mk () in
  let tree = Tree.Git.empty () in
  let hash =
    Store.Git.commit store ~tree ~parents:[] ~message:"test" ~author:"test"
  in
  Store.Git.set_head store ~branch:"main" hash;
  let branches = Store.Git.branches store in
  Alcotest.(check (list string)) "branches" [ "main" ] branches

let test_store_diff () =
  let store, backend = mk () in
  let tree1 = Tree.Git.empty () in
  let tree1 = Tree.Git.add tree1 [ "file1.txt" ] "content1" in
  let tree1 = Tree.Git.add tree1 [ "file2.txt" ] "content2" in
  let hash1 = Tree.Git.hash tree1 ~backend in
  let tree2 = Tree.Git.empty () in
  let tree2 = Tree.Git.add tree2 [ "file1.txt" ] "modified1" in
  let tree2 = Tree.Git.add tree2 [ "file3.txt" ] "content3" in
  let hash2 = Tree.Git.hash tree2 ~backend in
  let changes = Store.Git.diff store ~old:hash1 ~new_:hash2 |> List.of_seq in
  let has_remove = List.exists (function `Remove [ "file2.txt" ] -> true | _ -> false) changes in
  let has_add = List.exists (function `Add ([ "file3.txt" ], _) -> true | _ -> false) changes in
  let has_change = List.exists (function `Change ([ "file1.txt" ], _, _) -> true | _ -> false) changes in
  Alcotest.(check bool) "file2 removed" true has_remove;
  Alcotest.(check bool) "file3 added" true has_add;
  Alcotest.(check bool) "file1 changed" true has_change

(* ================================================================== *)
(* Multi-branch / merge-base                                           *)
(* ================================================================== *)

let test_multiple_branches () =
  let store, _ = mk () in
  let tree = Tree.Git.add (Tree.Git.empty ()) [ "f" ] "v" in
  let h1 = Store.Git.commit store ~tree ~parents:[] ~message:"c1" ~author:"a" in
  let h2 = Store.Git.commit store ~tree ~parents:[] ~message:"c2" ~author:"a" in
  Store.Git.set_head store ~branch:"main" h1;
  Store.Git.set_head store ~branch:"dev" h2;
  let branches = Store.Git.branches store |> List.sort String.compare in
  Alcotest.(check (list string)) "two branches" [ "dev"; "main" ] branches

let test_checkout () =
  let store, _ = mk () in
  let tree = Tree.Git.add (Tree.Git.empty ()) [ "file" ] "hello" in
  let h = Store.Git.commit store ~tree ~parents:[] ~message:"init" ~author:"a" in
  Store.Git.set_head store ~branch:"main" h;
  match Store.Git.checkout store ~branch:"main" with
  | Some t ->
      Alcotest.(check (option string)) "file" (Some "hello")
        (Tree.Git.find t [ "file" ])
  | None -> Alcotest.fail "checkout failed"

let test_commit_chain () =
  let store, _ = mk () in
  let t1 = Tree.Git.add (Tree.Git.empty ()) [ "f" ] "v1" in
  let h1 = Store.Git.commit store ~tree:t1 ~parents:[] ~message:"c1" ~author:"a" in
  let t2 = Tree.Git.add (Tree.Git.empty ()) [ "f" ] "v2" in
  let h2 = Store.Git.commit store ~tree:t2 ~parents:[h1] ~message:"c2" ~author:"a" in
  let t3 = Tree.Git.add (Tree.Git.empty ()) [ "f" ] "v3" in
  let h3 = Store.Git.commit store ~tree:t3 ~parents:[h2] ~message:"c3" ~author:"a" in
  (* is_ancestor *)
  Alcotest.(check bool) "h1 ancestor of h3" true
    (Store.Git.is_ancestor store ~ancestor:h1 ~descendant:h3);
  Alcotest.(check bool) "h3 not ancestor of h1" false
    (Store.Git.is_ancestor store ~ancestor:h3 ~descendant:h1);
  (* commits_between *)
  Alcotest.(check int) "2 commits between h1 and h3" 2
    (Store.Git.commits_between store ~base:h1 ~head:h3)

let test_merge_base () =
  let store, _ = mk () in
  let t = Tree.Git.add (Tree.Git.empty ()) [ "f" ] "base" in
  let base = Store.Git.commit store ~tree:t ~parents:[] ~message:"base" ~author:"a" in
  (* Two branches diverge from base *)
  let ta = Tree.Git.add (Tree.Git.empty ()) [ "f" ] "branch-a" in
  let ha = Store.Git.commit store ~tree:ta ~parents:[base] ~message:"a" ~author:"a" in
  let tb = Tree.Git.add (Tree.Git.empty ()) [ "f" ] "branch-b" in
  let hb = Store.Git.commit store ~tree:tb ~parents:[base] ~message:"b" ~author:"a" in
  match Store.Git.merge_base store ha hb with
  | Some mb ->
      Alcotest.(check string) "merge base is base"
        (Hash.to_hex base) (Hash.to_hex mb)
  | None -> Alcotest.fail "merge_base returned None"

let test_update_branch () =
  let store, _ = mk () in
  let tree = Tree.Git.add (Tree.Git.empty ()) [ "f" ] "v" in
  let h1 = Store.Git.commit store ~tree ~parents:[] ~message:"c1" ~author:"a" in
  let h2 = Store.Git.commit store ~tree ~parents:[h1] ~message:"c2" ~author:"a" in
  Store.Git.set_head store ~branch:"main" h1;
  (* CAS: update main from h1 to h2 *)
  let ok = Store.Git.update_branch store ~branch:"main" ~old:(Some h1) ~new_:h2 in
  Alcotest.(check bool) "CAS success" true ok;
  Alcotest.(check (option string)) "head updated"
    (Some (Hash.to_hex h2))
    (Option.map Hash.to_hex (Store.Git.head store ~branch:"main"));
  (* CAS: fail if old doesn't match *)
  let fail = Store.Git.update_branch store ~branch:"main" ~old:(Some h1) ~new_:h1 in
  Alcotest.(check bool) "CAS fail" false fail

let test_diff_no_change () =
  let store, backend = mk () in
  let tree = Tree.Git.add (Tree.Git.empty ()) [ "f" ] "v" in
  let h = Tree.Git.hash tree ~backend in
  let changes = Store.Git.diff store ~old:h ~new_:h |> List.of_seq in
  Alcotest.(check int) "no changes" 0 (List.length changes)

let suite =
  ( "Store",
    [
      (* Basic *)
      Alcotest.test_case "commit" `Quick test_store_commit;
      Alcotest.test_case "branches" `Quick test_store_branches;
      Alcotest.test_case "diff" `Quick test_store_diff;
      (* Multi-branch / merge *)
      Alcotest.test_case "multiple branches" `Quick test_multiple_branches;
      Alcotest.test_case "checkout" `Quick test_checkout;
      Alcotest.test_case "commit chain + ancestry" `Quick test_commit_chain;
      Alcotest.test_case "merge base" `Quick test_merge_base;
      Alcotest.test_case "update branch (CAS)" `Quick test_update_branch;
      Alcotest.test_case "diff no change" `Quick test_diff_no_change;
    ] )
