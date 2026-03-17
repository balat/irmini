open Irmin

(* ================================================================== *)
(* Basic tests (existing)                                              *)
(* ================================================================== *)

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

(* ================================================================== *)
(* mem / mem_tree                                                      *)
(* ================================================================== *)

let test_mem () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "a"; "b" ] "v" in
  let tree = Tree.Git.add tree [ "c" ] "v2" in
  Alcotest.(check bool) "mem leaf" true (Tree.Git.mem tree [ "a"; "b" ]);
  Alcotest.(check bool) "mem content at root" true (Tree.Git.mem tree [ "c" ]);
  Alcotest.(check bool) "mem missing" false (Tree.Git.mem tree [ "a"; "c" ]);
  Alcotest.(check bool) "mem nonexistent" false (Tree.Git.mem tree [ "z" ])

let test_mem_tree () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "a"; "b" ] "v" in
  Alcotest.(check bool) "mem_tree subtree" true (Tree.Git.mem_tree tree [ "a" ]);
  (* a/b is a content leaf, not a subtree *)
  Alcotest.(check bool) "mem_tree leaf" false (Tree.Git.mem_tree tree [ "a"; "b" ]);
  Alcotest.(check bool) "mem_tree missing" false (Tree.Git.mem_tree tree [ "x" ])

(* ================================================================== *)
(* list                                                                *)
(* ================================================================== *)

let test_list () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "b" ] "2" in
  let tree = Tree.Git.add tree [ "a" ] "1" in
  let tree = Tree.Git.add tree [ "c" ] "3" in
  let names = List.map fst (Tree.Git.list tree []) in
  Alcotest.(check int) "3 entries" 3 (List.length names);
  Alcotest.(check bool) "has a" true (List.mem "a" names);
  Alcotest.(check bool) "has b" true (List.mem "b" names);
  Alcotest.(check bool) "has c" true (List.mem "c" names)

let test_list_nested () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "dir"; "f1" ] "v1" in
  let tree = Tree.Git.add tree [ "dir"; "f2" ] "v2" in
  let tree = Tree.Git.add tree [ "top" ] "v3" in
  let top = List.map fst (Tree.Git.list tree []) in
  Alcotest.(check int) "2 top entries" 2 (List.length top);
  let sub = List.map fst (Tree.Git.list tree [ "dir" ]) in
  Alcotest.(check int) "2 sub entries" 2 (List.length sub)

(* ================================================================== *)
(* find_tree / add_tree                                                *)
(* ================================================================== *)

let test_find_tree () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "a"; "b" ] "v" in
  match Tree.Git.find_tree tree [ "a" ] with
  | Some sub ->
      Alcotest.(check (option string)) "find in subtree" (Some "v")
        (Tree.Git.find sub [ "b" ])
  | None -> Alcotest.fail "subtree not found"

let test_add_tree () =
  let sub = Tree.Git.empty () in
  let sub = Tree.Git.add sub [ "x" ] "vx" in
  let sub = Tree.Git.add sub [ "y" ] "vy" in
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add_tree tree [ "dir" ] sub in
  Alcotest.(check (option string)) "find x" (Some "vx")
    (Tree.Git.find tree [ "dir"; "x" ]);
  Alcotest.(check (option string)) "find y" (Some "vy")
    (Tree.Git.find tree [ "dir"; "y" ])

(* ================================================================== *)
(* Large trees                                                         *)
(* ================================================================== *)

let test_large_flat () =
  (* 1000 entries at root level *)
  let tree = ref (Tree.Git.empty ()) in
  for i = 0 to 999 do
    tree := Tree.Git.add !tree [ Printf.sprintf "key-%04d" i ]
        (Printf.sprintf "value-%d" i)
  done;
  (* Verify all entries *)
  for i = 0 to 999 do
    let key = Printf.sprintf "key-%04d" i in
    let expected = Printf.sprintf "value-%d" i in
    Alcotest.(check (option string)) key (Some expected)
      (Tree.Git.find !tree [ key ])
  done;
  (* List should return all entries *)
  let entries = Tree.Git.list !tree [] in
  Alcotest.(check int) "1000 entries" 1000 (List.length entries)

let test_large_deep () =
  (* Deep nesting: 50 levels *)
  let path = List.init 50 (fun i -> Printf.sprintf "level-%d" i) in
  let tree = Tree.Git.add (Tree.Git.empty ()) path "deep-value" in
  Alcotest.(check (option string)) "find deep" (Some "deep-value")
    (Tree.Git.find tree path);
  (* Intermediate paths should be trees *)
  let partial = List.filteri (fun i _ -> i < 25) path in
  Alcotest.(check bool) "mem_tree at 25" true
    (Tree.Git.mem_tree tree partial)

let test_large_wide_and_deep () =
  (* 100 directories × 100 files = 10000 entries *)
  let tree = ref (Tree.Git.empty ()) in
  for d = 0 to 99 do
    for f = 0 to 99 do
      let dir = Printf.sprintf "dir-%02d" d in
      let file = Printf.sprintf "file-%02d" f in
      tree := Tree.Git.add !tree [ dir; file ]
          (Printf.sprintf "v-%d-%d" d f)
    done
  done;
  (* Spot checks *)
  Alcotest.(check (option string)) "0-0" (Some "v-0-0")
    (Tree.Git.find !tree [ "dir-00"; "file-00" ]);
  Alcotest.(check (option string)) "99-99" (Some "v-99-99")
    (Tree.Git.find !tree [ "dir-99"; "file-99" ]);
  Alcotest.(check (option string)) "50-50" (Some "v-50-50")
    (Tree.Git.find !tree [ "dir-50"; "file-50" ]);
  (* List directories *)
  let dirs = Tree.Git.list !tree [] in
  Alcotest.(check int) "100 dirs" 100 (List.length dirs);
  (* List files in one dir *)
  let files = Tree.Git.list !tree [ "dir-42" ] in
  Alcotest.(check int) "100 files" 100 (List.length files)

let test_large_remove_half () =
  let tree = ref (Tree.Git.empty ()) in
  for i = 0 to 999 do
    tree := Tree.Git.add !tree [ Printf.sprintf "k%d" i ]
        (Printf.sprintf "v%d" i)
  done;
  (* Remove even entries *)
  for i = 0 to 999 do
    if i mod 2 = 0 then
      tree := Tree.Git.remove !tree [ Printf.sprintf "k%d" i ]
  done;
  (* Verify *)
  for i = 0 to 999 do
    let key = Printf.sprintf "k%d" i in
    let expected = if i mod 2 = 0 then None else Some (Printf.sprintf "v%d" i) in
    Alcotest.(check (option string)) key expected
      (Tree.Git.find !tree [ key ])
  done;
  let entries = Tree.Git.list !tree [] in
  Alcotest.(check int) "500 remaining" 500 (List.length entries)

(* ================================================================== *)
(* Persistence roundtrip (commit + checkout)                           *)
(* ================================================================== *)

let test_persistence_roundtrip () =
  let backend = Backend.Memory.create_sha1 () in
  let store = Store.Git.create ~backend () in
  (* Build a non-trivial tree *)
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "a"; "b" ] "v1" in
  let tree = Tree.Git.add tree [ "a"; "c" ] "v2" in
  let tree = Tree.Git.add tree [ "d" ] "v3" in
  let h = Store.Git.commit store ~tree ~parents:[] ~message:"test"
      ~author:"test" in
  Store.Git.set_head store ~branch:"main" h;
  (* Read back *)
  match Store.Git.checkout store ~branch:"main" with
  | Some tree' ->
      Alcotest.(check (option string)) "a/b" (Some "v1")
        (Tree.Git.find tree' [ "a"; "b" ]);
      Alcotest.(check (option string)) "a/c" (Some "v2")
        (Tree.Git.find tree' [ "a"; "c" ]);
      Alcotest.(check (option string)) "d" (Some "v3")
        (Tree.Git.find tree' [ "d" ])
  | None -> Alcotest.fail "checkout failed"

(* ================================================================== *)
(* fold                                                                *)
(* ================================================================== *)

let test_fold_contents () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "a" ] "va" in
  let tree = Tree.Git.add tree [ "b"; "c" ] "vbc" in
  let tree = Tree.Git.add tree [ "d" ] "vd" in
  let found =
    Tree.Git.fold ~force:`True tree [] (fun path kind acc ->
        match kind with `Contents _ -> path :: acc | `Tree -> acc)
  in
  Alcotest.(check int) "3 contents" 3 (List.length found)

let test_fold_trees () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "a"; "b" ] "v1" in
  let tree = Tree.Git.add tree [ "c" ] "v2" in
  let trees =
    Tree.Git.fold ~force:`True tree [] (fun path kind acc ->
        match kind with `Tree -> path :: acc | `Contents _ -> acc)
  in
  (* root + "a" subtree = at least 2 tree nodes *)
  Alcotest.(check bool) "has tree nodes" true (List.length trees >= 2)

let test_fold_force_false () =
  let backend = Backend.Memory.create_sha1 () in
  let store = Store.Git.create ~backend () in
  let tree = Tree.Git.add (Tree.Git.empty ()) [ "x" ] "v" in
  let h = Store.Git.commit store ~tree ~parents:[] ~message:"t" ~author:"t" in
  Store.Git.set_head store ~branch:"main" h;
  match Store.Git.checkout store ~branch:"main" with
  | None -> Alcotest.fail "checkout failed"
  | Some lazy_tree ->
      (* With force:`False, unloaded nodes call the callback *)
      let unloaded = ref 0 in
      let _n =
        Tree.Git.fold
          ~force:(`False (fun _h -> incr unloaded; 0))
          lazy_tree 0
          (fun _path _kind acc -> acc + 1)
      in
      (* We just check it doesn't crash *)
      Alcotest.(check bool) "fold with force:false completes" true true

(* ================================================================== *)
(* concrete roundtrip                                                  *)
(* ================================================================== *)

let test_concrete_roundtrip () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "a"; "b" ] "v1" in
  let tree = Tree.Git.add tree [ "a"; "c" ] "v2" in
  let tree = Tree.Git.add tree [ "d" ] "v3" in
  let concrete = Tree.Git.to_concrete tree in
  let tree2 = Tree.Git.of_concrete concrete in
  Alcotest.(check (option string)) "a/b" (Some "v1")
    (Tree.Git.find tree2 [ "a"; "b" ]);
  Alcotest.(check (option string)) "a/c" (Some "v2")
    (Tree.Git.find tree2 [ "a"; "c" ]);
  Alcotest.(check (option string)) "d" (Some "v3")
    (Tree.Git.find tree2 [ "d" ])

let test_concrete_empty () =
  let tree = Tree.Git.empty () in
  let concrete = Tree.Git.to_concrete tree in
  let tree2 = Tree.Git.of_concrete concrete in
  let entries = Tree.Git.list tree2 [] in
  Alcotest.(check int) "empty concrete" 0 (List.length entries)

(* ================================================================== *)
(* equal                                                               *)
(* ================================================================== *)

let test_equal_same () =
  let tree = Tree.Git.add (Tree.Git.empty ()) [ "k" ] "v" in
  Alcotest.(check bool) "same tree" true (Tree.Git.equal tree tree)

let test_equal_different () =
  let t1 = Tree.Git.add (Tree.Git.empty ()) [ "k" ] "v1" in
  let t2 = Tree.Git.add (Tree.Git.empty ()) [ "k" ] "v2" in
  Alcotest.(check bool) "different trees" false (Tree.Git.equal t1 t2)

let test_equal_structural () =
  (* Two independently built trees with same content should be equal *)
  let t1 = Tree.Git.add (Tree.Git.empty ()) [ "a"; "b" ] "v" in
  let t1 = Tree.Git.add t1 [ "c" ] "w" in
  let t2 = Tree.Git.add (Tree.Git.empty ()) [ "a"; "b" ] "v" in
  let t2 = Tree.Git.add t2 [ "c" ] "w" in
  Alcotest.(check bool) "structurally equal" true (Tree.Git.equal t1 t2)

let test_equal_empty () =
  Alcotest.(check bool) "empty trees equal" true
    (Tree.Git.equal (Tree.Git.empty ()) (Tree.Git.empty ()))

(* ================================================================== *)
(* shallow / pruned                                                    *)
(* ================================================================== *)

let test_shallow () =
  let backend = Backend.Memory.create_sha1 () in
  let store = Store.Git.create ~backend () in
  let tree = Tree.Git.add (Tree.Git.empty ()) [ "x" ] "v" in
  let h = Store.Git.commit store ~tree ~parents:[] ~message:"t" ~author:"t" in
  Store.Git.set_head store ~branch:"main" h;
  match Store.Git.checkout store ~branch:"main" with
  | None -> Alcotest.fail "checkout failed"
  | Some loaded_tree ->
      let tree_hash = Tree.Git.hash loaded_tree ~backend in
      let shallow = Tree.Git.shallow tree_hash in
      (* Shallow tree: list returns nothing (not loaded), but
         of_hash with the same hash can read the data *)
      let reloaded = Tree.Git.of_hash ~backend tree_hash in
      Alcotest.(check (option string)) "reloaded from shallow hash"
        (Some "v") (Tree.Git.find reloaded [ "x" ]);
      (* The shallow tree itself cannot access data (no backend) *)
      Alcotest.(check (option string)) "shallow has no data" None
        (Tree.Git.find shallow [ "x" ])

let test_pruned () =
  let h = Hash.sha1 "fake-tree-hash" in
  let pruned = Tree.Git.pruned h in
  (* Pruned tree: find returns None (no backend, no data) *)
  Alcotest.(check (option string)) "pruned has no data" None
    (Tree.Git.find pruned [ "x" ]);
  (* List returns nothing *)
  Alcotest.(check int) "pruned list empty" 0
    (List.length (Tree.Git.list pruned []))

(* ================================================================== *)
(* clear                                                               *)
(* ================================================================== *)

let test_clear () =
  let backend = Backend.Memory.create_sha1 () in
  let store = Store.Git.create ~backend () in
  let tree = Tree.Git.add (Tree.Git.empty ()) [ "a"; "b" ] "v" in
  let h = Store.Git.commit store ~tree ~parents:[] ~message:"t" ~author:"t" in
  Store.Git.set_head store ~branch:"main" h;
  match Store.Git.checkout store ~branch:"main" with
  | None -> Alcotest.fail "checkout failed"
  | Some lazy_tree ->
      (* Force load *)
      ignore (Tree.Git.find lazy_tree [ "a"; "b" ]);
      (* Clear cache *)
      Tree.Git.clear lazy_tree;
      (* Should still be accessible (re-loaded lazily) *)
      Alcotest.(check (option string)) "after clear" (Some "v")
        (Tree.Git.find lazy_tree [ "a"; "b" ])

let test_clear_depth () =
  let backend = Backend.Memory.create_sha1 () in
  let store = Store.Git.create ~backend () in
  let tree = Tree.Git.add (Tree.Git.empty ()) [ "a"; "b"; "c" ] "deep" in
  let tree = Tree.Git.add tree [ "x" ] "shallow" in
  let h = Store.Git.commit store ~tree ~parents:[] ~message:"t" ~author:"t" in
  Store.Git.set_head store ~branch:"main" h;
  match Store.Git.checkout store ~branch:"main" with
  | None -> Alcotest.fail "checkout failed"
  | Some lazy_tree ->
      ignore (Tree.Git.find lazy_tree [ "a"; "b"; "c" ]);
      ignore (Tree.Git.find lazy_tree [ "x" ]);
      Tree.Git.clear ~depth:2 lazy_tree;
      (* Both should still be accessible *)
      Alcotest.(check (option string)) "deep after clear" (Some "deep")
        (Tree.Git.find lazy_tree [ "a"; "b"; "c" ]);
      Alcotest.(check (option string)) "shallow after clear" (Some "shallow")
        (Tree.Git.find lazy_tree [ "x" ])

let suite =
  ( "Tree",
    [
      (* Basic *)
      Alcotest.test_case "empty tree" `Quick test_empty_tree;
      Alcotest.test_case "add/find" `Quick test_tree_add_find;
      Alcotest.test_case "remove" `Quick test_tree_remove;
      Alcotest.test_case "overwrite" `Quick test_tree_overwrite;
      Alcotest.test_case "nested" `Quick test_tree_nested;
      (* mem / mem_tree *)
      Alcotest.test_case "mem" `Quick test_mem;
      Alcotest.test_case "mem_tree" `Quick test_mem_tree;
      (* list *)
      Alcotest.test_case "list" `Quick test_list;
      Alcotest.test_case "list nested" `Quick test_list_nested;
      (* find_tree / add_tree *)
      Alcotest.test_case "find_tree" `Quick test_find_tree;
      Alcotest.test_case "add_tree" `Quick test_add_tree;
      (* Large trees *)
      Alcotest.test_case "large flat (1000)" `Quick test_large_flat;
      Alcotest.test_case "large deep (50 levels)" `Quick test_large_deep;
      Alcotest.test_case "large wide+deep (10k)" `Quick test_large_wide_and_deep;
      Alcotest.test_case "large remove half" `Quick test_large_remove_half;
      (* Persistence *)
      Alcotest.test_case "persistence roundtrip" `Quick test_persistence_roundtrip;
      (* fold *)
      Alcotest.test_case "fold contents" `Quick test_fold_contents;
      Alcotest.test_case "fold trees" `Quick test_fold_trees;
      Alcotest.test_case "fold force:false" `Quick test_fold_force_false;
      (* concrete *)
      Alcotest.test_case "concrete roundtrip" `Quick test_concrete_roundtrip;
      Alcotest.test_case "concrete empty" `Quick test_concrete_empty;
      (* equal *)
      Alcotest.test_case "equal same" `Quick test_equal_same;
      Alcotest.test_case "equal different" `Quick test_equal_different;
      Alcotest.test_case "equal structural" `Quick test_equal_structural;
      Alcotest.test_case "equal empty" `Quick test_equal_empty;
      (* shallow / pruned *)
      Alcotest.test_case "shallow" `Quick test_shallow;
      Alcotest.test_case "pruned" `Quick test_pruned;
      (* clear *)
      Alcotest.test_case "clear" `Quick test_clear;
      Alcotest.test_case "clear depth" `Quick test_clear_depth;
    ] )
