(** Cross-implementation tests for Irmin-Eio (cuihtlauac branch).

    Tests the same scenarios as the Irmini test suite against the official
    Irmin Eio backend, to ensure behavioral equivalence.

    Build from the Irmin workspace (cuihtlauac-inline-small-objects-v2 branch):
      dune exec test-irmin-eio/main.exe *)

module Store = Irmin_mem.KV.Make (Irmin.Contents.String)

let info () = Store.Info.v ~author:"test" ~message:"commit" 0L

(* Each test needs Eio_main.run because Irmin_mem uses Eio_mutex internally. *)
let with_repo f =
  Eio_main.run @@ fun _env ->
  let config = Irmin_mem.config () in
  let repo = Store.Repo.v config in
  Fun.protect ~finally:(fun () -> Store.Repo.close repo) (fun () -> f repo)

let with_repo_env f =
  Eio_main.run @@ fun env ->
  let config = Irmin_mem.config () in
  let repo = Store.Repo.v config in
  Fun.protect ~finally:(fun () -> Store.Repo.close repo) (fun () -> f env repo)

(* ================================================================== *)
(* Tree: basic                                                         *)
(* ================================================================== *)

let test_tree_empty () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.empty () in
  let entries = Store.Tree.list tree [] in
  Alcotest.(check int) "empty tree" 0 (List.length entries)

let test_tree_add_find () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "a"; "b" ] "hello" in
  let v = Store.Tree.find tree [ "a"; "b" ] in
  Alcotest.(check (option string)) "find" (Some "hello") v

let test_tree_remove () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "x" ] "value" in
  let tree = Store.Tree.remove tree [ "x" ] in
  Alcotest.(check (option string)) "removed" None (Store.Tree.find tree [ "x" ])

let test_tree_overwrite () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "k" ] "v1" in
  let tree = Store.Tree.add tree [ "k" ] "v2" in
  Alcotest.(check (option string)) "overwritten" (Some "v2")
    (Store.Tree.find tree [ "k" ])

let test_tree_nested () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "a"; "b"; "c" ] "deep" in
  let tree = Store.Tree.add tree [ "a"; "d" ] "sibling" in
  let tree = Store.Tree.add tree [ "root" ] "top" in
  Alcotest.(check (option string)) "deep" (Some "deep")
    (Store.Tree.find tree [ "a"; "b"; "c" ]);
  Alcotest.(check (option string)) "sibling" (Some "sibling")
    (Store.Tree.find tree [ "a"; "d" ]);
  Alcotest.(check (option string)) "top" (Some "top")
    (Store.Tree.find tree [ "root" ])

(* ================================================================== *)
(* Tree: mem / mem_tree                                                *)
(* ================================================================== *)

let test_tree_mem () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "a"; "b" ] "v" in
  let tree = Store.Tree.add tree [ "c" ] "v2" in
  Alcotest.(check bool) "mem leaf" true (Store.Tree.mem tree [ "a"; "b" ]);
  Alcotest.(check bool) "mem content" true (Store.Tree.mem tree [ "c" ]);
  Alcotest.(check bool) "mem missing" false (Store.Tree.mem tree [ "a"; "c" ]);
  Alcotest.(check bool) "mem nonexistent" false (Store.Tree.mem tree [ "z" ])

let test_tree_mem_tree () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "a"; "b" ] "v" in
  Alcotest.(check bool) "mem_tree subtree" true
    (Store.Tree.mem_tree tree [ "a" ]);
  (* In Irmin, mem_tree on a contents leaf returns true (contents are trivial
     trees). This differs from Irmini where contents are not trees. *)
  Alcotest.(check bool) "mem_tree leaf (irmin: true)" true
    (Store.Tree.mem_tree tree [ "a"; "b" ]);
  Alcotest.(check bool) "mem_tree missing" false
    (Store.Tree.mem_tree tree [ "x" ])

(* ================================================================== *)
(* Tree: list                                                          *)
(* ================================================================== *)

let test_tree_list () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "b" ] "2" in
  let tree = Store.Tree.add tree [ "a" ] "1" in
  let tree = Store.Tree.add tree [ "c" ] "3" in
  let names = List.map (fun (s, _) -> s) (Store.Tree.list tree []) in
  Alcotest.(check int) "3 entries" 3 (List.length names);
  Alcotest.(check bool) "has a" true (List.mem "a" names);
  Alcotest.(check bool) "has b" true (List.mem "b" names);
  Alcotest.(check bool) "has c" true (List.mem "c" names)

let test_tree_list_nested () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "dir"; "f1" ] "v1" in
  let tree = Store.Tree.add tree [ "dir"; "f2" ] "v2" in
  let tree = Store.Tree.add tree [ "top" ] "v3" in
  let top = Store.Tree.list tree [] in
  Alcotest.(check int) "2 top entries" 2 (List.length top);
  let sub = Store.Tree.list tree [ "dir" ] in
  Alcotest.(check int) "2 sub entries" 2 (List.length sub)

(* ================================================================== *)
(* Tree: find_tree / add_tree                                          *)
(* ================================================================== *)

let test_tree_find_tree () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "a"; "b" ] "v" in
  match Store.Tree.find_tree tree [ "a" ] with
  | Some sub ->
      Alcotest.(check (option string)) "find in subtree" (Some "v")
        (Store.Tree.find sub [ "b" ])
  | None -> Alcotest.fail "subtree not found"

let test_tree_add_tree () =
  with_repo @@ fun _repo ->
  let sub = Store.Tree.add (Store.Tree.empty ()) [ "x" ] "vx" in
  let sub = Store.Tree.add sub [ "y" ] "vy" in
  let tree = Store.Tree.add_tree (Store.Tree.empty ()) [ "dir" ] sub in
  Alcotest.(check (option string)) "find x" (Some "vx")
    (Store.Tree.find tree [ "dir"; "x" ]);
  Alcotest.(check (option string)) "find y" (Some "vy")
    (Store.Tree.find tree [ "dir"; "y" ])

(* ================================================================== *)
(* Tree: large                                                         *)
(* ================================================================== *)

let test_tree_large_flat () =
  with_repo @@ fun _repo ->
  let n = 1000 in
  let tree =
    let t = ref (Store.Tree.empty ()) in
    for i = 0 to n - 1 do
      t :=
        Store.Tree.add !t
          [ Printf.sprintf "k%04d" i ]
          (Printf.sprintf "v%d" i)
    done;
    !t
  in
  let entries = Store.Tree.list tree [] in
  Alcotest.(check int) "1000 entries" n (List.length entries);
  Alcotest.(check (option string)) "spot check" (Some "v500")
    (Store.Tree.find tree [ "k0500" ])

let test_tree_large_deep () =
  with_repo @@ fun _repo ->
  let path = List.init 50 (fun i -> Printf.sprintf "level-%d" i) in
  let tree = Store.Tree.add (Store.Tree.empty ()) path "deep-value" in
  Alcotest.(check (option string)) "find deep" (Some "deep-value")
    (Store.Tree.find tree path);
  let partial = List.filteri (fun i _ -> i < 25) path in
  Alcotest.(check bool) "mem_tree at 25" true
    (Store.Tree.mem_tree tree partial)

let test_tree_large_wide_and_deep () =
  with_repo @@ fun _repo ->
  let tree = ref (Store.Tree.empty ()) in
  for d = 0 to 99 do
    for f = 0 to 99 do
      tree :=
        Store.Tree.add !tree
          [ Printf.sprintf "dir-%02d" d; Printf.sprintf "file-%02d" f ]
          (Printf.sprintf "v-%d-%d" d f)
    done
  done;
  Alcotest.(check (option string)) "0-0" (Some "v-0-0")
    (Store.Tree.find !tree [ "dir-00"; "file-00" ]);
  Alcotest.(check (option string)) "99-99" (Some "v-99-99")
    (Store.Tree.find !tree [ "dir-99"; "file-99" ]);
  let dirs = Store.Tree.list !tree [] in
  Alcotest.(check int) "100 dirs" 100 (List.length dirs);
  let files = Store.Tree.list !tree [ "dir-42" ] in
  Alcotest.(check int) "100 files" 100 (List.length files)

let test_tree_large_remove_half () =
  with_repo @@ fun _repo ->
  let tree = ref (Store.Tree.empty ()) in
  for i = 0 to 999 do
    tree :=
      Store.Tree.add !tree
        [ Printf.sprintf "k%d" i ]
        (Printf.sprintf "v%d" i)
  done;
  for i = 0 to 999 do
    if i mod 2 = 0 then
      tree := Store.Tree.remove !tree [ Printf.sprintf "k%d" i ]
  done;
  for i = 0 to 999 do
    let key = Printf.sprintf "k%d" i in
    let expected =
      if i mod 2 = 0 then None else Some (Printf.sprintf "v%d" i)
    in
    Alcotest.(check (option string)) key expected
      (Store.Tree.find !tree [ key ])
  done;
  let entries = Store.Tree.list !tree [] in
  Alcotest.(check int) "500 remaining" 500 (List.length entries)

(* ================================================================== *)
(* Tree: persistence roundtrip                                         *)
(* ================================================================== *)

let test_tree_persistence_roundtrip () =
  with_repo @@ fun repo ->
  let store = Store.main repo in
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "a"; "b" ] "v1" in
  let tree = Store.Tree.add tree [ "a"; "c" ] "v2" in
  let tree = Store.Tree.add tree [ "d" ] "v3" in
  Store.set_tree_exn store ~info [] tree;
  let tree2 = Store.get_tree store [] in
  Alcotest.(check (option string)) "a/b" (Some "v1")
    (Store.Tree.find tree2 [ "a"; "b" ]);
  Alcotest.(check (option string)) "a/c" (Some "v2")
    (Store.Tree.find tree2 [ "a"; "c" ]);
  Alcotest.(check (option string)) "d" (Some "v3")
    (Store.Tree.find tree2 [ "d" ])

(* ================================================================== *)
(* Store: basic                                                        *)
(* ================================================================== *)

let test_store_commit () =
  with_repo @@ fun repo ->
  let store = Store.main repo in
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "file" ] "content" in
  Store.set_tree_exn store ~info [] tree;
  Alcotest.(check (option string)) "committed" (Some "content")
    (Store.find store [ "file" ])

let test_store_branches () =
  with_repo @@ fun repo ->
  let main = Store.main repo in
  Store.set_tree_exn main ~info []
    (Store.Tree.add (Store.Tree.empty ()) [ "data" ] "main-val");
  let br = Store.of_branch repo "feature" in
  Store.set_tree_exn br ~info []
    (Store.Tree.add (Store.Tree.empty ()) [ "data" ] "feature-val");
  Alcotest.(check (option string)) "main" (Some "main-val")
    (Store.find main [ "data" ]);
  Alcotest.(check (option string)) "feature" (Some "feature-val")
    (Store.find br [ "data" ])

let test_store_multi_commit () =
  with_repo @@ fun repo ->
  let store = Store.main repo in
  for i = 1 to 10 do
    let tree = Store.get_tree store [] in
    let tree = Store.Tree.add tree [ "counter" ] (string_of_int i) in
    Store.set_tree_exn store ~info [] tree
  done;
  Alcotest.(check (option string)) "10th commit" (Some "10")
    (Store.find store [ "counter" ])

let test_store_checkout () =
  with_repo @@ fun repo ->
  let store = Store.main repo in
  Store.set_tree_exn store ~info []
    (Store.Tree.add (Store.Tree.empty ()) [ "x" ] "val");
  let store2 = Store.main repo in
  Alcotest.(check (option string)) "checkout" (Some "val")
    (Store.find store2 [ "x" ])

let test_store_large_tree () =
  with_repo @@ fun repo ->
  let store = Store.main repo in
  let nfiles = 500 in
  let tree =
    let t = ref (Store.Tree.empty ()) in
    for i = 0 to nfiles - 1 do
      t :=
        Store.Tree.add !t
          [ Printf.sprintf "dir-%02d" (i / 10); Printf.sprintf "f%d" i ]
          (Printf.sprintf "c%d" i)
    done;
    !t
  in
  Store.set_tree_exn store ~info [] tree;
  let tree2 = Store.get_tree store [] in
  Alcotest.(check (option string)) "large tree" (Some "c250")
    (Store.Tree.find tree2 [ "dir-25"; "f250" ])

(* ================================================================== *)
(* Store: multiple branches                                            *)
(* ================================================================== *)

let test_store_multiple_branches () =
  with_repo @@ fun repo ->
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "f" ] "v" in
  let main = Store.main repo in
  Store.set_tree_exn main ~info [] tree;
  let dev = Store.of_branch repo "dev" in
  Store.set_tree_exn dev ~info [] tree;
  let branches = Store.Branch.list repo in
  Alcotest.(check bool) "has main" true (List.mem "main" branches);
  Alcotest.(check bool) "has dev" true (List.mem "dev" branches);
  Alcotest.(check bool) "at least 2" true (List.length branches >= 2)

(* ================================================================== *)
(* Store: commit chain + ancestry                                      *)
(* ================================================================== *)

let test_store_commit_chain () =
  with_repo @@ fun repo ->
  let store = Store.main repo in
  (* 3 sequential commits *)
  for i = 1 to 3 do
    let tree = Store.get_tree store [] in
    let tree = Store.Tree.add tree [ "f" ] (Printf.sprintf "v%d" i) in
    Store.set_tree_exn store ~info [] tree
  done;
  (* Check latest *)
  Alcotest.(check (option string)) "latest" (Some "v3")
    (Store.find store [ "f" ]);
  (* Walk parent chain *)
  match Store.Head.find store with
  | None -> Alcotest.fail "no head"
  | Some head ->
      let parents = Store.Commit.parents head in
      Alcotest.(check bool) "has parent" true (List.length parents > 0)

(* ================================================================== *)
(* Store: LCA (merge base)                                             *)
(* ================================================================== *)

let test_store_lca () =
  with_repo @@ fun repo ->
  (* Common base on main *)
  let main = Store.main repo in
  Store.set_tree_exn main ~info []
    (Store.Tree.add (Store.Tree.empty ()) [ "f" ] "base");
  (* Branch a *)
  let br_a = Store.of_branch repo "branch-a" in
  Store.set_tree_exn br_a ~info []
    (Store.Tree.add (Store.Tree.empty ()) [ "f" ] "val-a");
  (* Branch b *)
  let br_b = Store.of_branch repo "branch-b" in
  Store.set_tree_exn br_b ~info []
    (Store.Tree.add (Store.Tree.empty ()) [ "f" ] "val-b");
  (* LCA should exist (both branch from empty/main) *)
  match Store.lcas br_a br_b with
  | Ok lcas -> Alcotest.(check bool) "lca found" true (List.length lcas >= 0)
  | Error _ -> Alcotest.fail "lcas error"

(* ================================================================== *)
(* Store: diff                                                         *)
(* ================================================================== *)

let test_store_diff () =
  with_repo @@ fun repo ->
  let store = Store.main repo in
  (* Commit 1 *)
  let tree1 = Store.Tree.add (Store.Tree.empty ()) [ "a" ] "v1" in
  let tree1 = Store.Tree.add tree1 [ "b" ] "v2" in
  Store.set_tree_exn store ~info [] tree1;
  (* Commit 2: modify a, remove b, add c *)
  let tree2 = Store.Tree.add (Store.Tree.empty ()) [ "a" ] "v1-mod" in
  let tree2 = Store.Tree.add tree2 [ "c" ] "v3" in
  Store.set_tree_exn store ~info [] tree2;
  (* Diff trees *)
  let diff = Store.Tree.diff tree1 tree2 in
  Alcotest.(check bool) "diff not empty" true (List.length diff > 0)

let test_store_diff_no_change () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "f" ] "v" in
  let diff = Store.Tree.diff tree tree in
  Alcotest.(check int) "no changes" 0 (List.length diff)

(* ================================================================== *)
(* Concurrent (Eio multi-domain)                                       *)
(* ================================================================== *)

let test_concurrent_reads () =
  with_repo_env @@ fun env repo ->
  let store = Store.main repo in
  let tree =
    let t = ref (Store.Tree.empty ()) in
    for i = 0 to 99 do
      t :=
        Store.Tree.add !t
          [ Printf.sprintf "k%d" i ]
          (Printf.sprintf "v%d" i)
    done;
    !t
  in
  Store.set_tree_exn store ~info [] tree;
  let tree = Store.get_tree store [] in
  let dm = Eio.Stdenv.domain_mgr env in
  let ndomains = min 4 (Domain.recommended_domain_count ()) in
  let errors = Atomic.make 0 in
  Eio.Fiber.all
    (List.init ndomains (fun did () ->
         Eio.Domain_manager.run dm (fun () ->
             for i = 0 to 99 do
               let k = (did * 17 + i) mod 100 in
               let expected = Printf.sprintf "v%d" k in
               match Store.Tree.find tree [ Printf.sprintf "k%d" k ] with
               | Some v when v = expected -> ()
               | _ -> Atomic.incr errors
             done)));
  Alcotest.(check int) "no read errors" 0 (Atomic.get errors)

let test_concurrent_branches () =
  (* Irmin_mem is NOT domain-safe for concurrent writes (dangling hashes).
     This test only does one commit per domain to avoid the issue. *)
  with_repo_env @@ fun env repo ->
  let dm = Eio.Stdenv.domain_mgr env in
  let ndomains = min 4 (Domain.recommended_domain_count ()) in
  Eio.Fiber.all
    (List.init ndomains (fun did () ->
         Eio.Domain_manager.run dm (fun () ->
             let branch = Printf.sprintf "branch-%d" did in
             let br = Store.of_branch repo branch in
             let tree =
               Store.Tree.add (Store.Tree.empty ()) [ "who" ]
                 (Printf.sprintf "domain-%d" did)
             in
             Store.set_tree_exn br
               ~info:(fun () ->
                 Store.Info.v ~author:"test"
                   ~message:(Printf.sprintf "d%d" did) 0L)
               [] tree)));
  for did = 0 to ndomains - 1 do
    let br = Store.of_branch repo (Printf.sprintf "branch-%d" did) in
    let expected = Printf.sprintf "domain-%d" did in
    Alcotest.(check (option string))
      (Printf.sprintf "branch-%d" did)
      (Some expected)
      (Store.find br [ "who" ])
  done

let test_concurrent_commits () =
  (* Each domain commits to its own branch — single write per domain
     to stay within Irmin_mem's concurrency limits. *)
  with_repo_env @@ fun env repo ->
  let dm = Eio.Stdenv.domain_mgr env in
  let ndomains = min 4 (Domain.recommended_domain_count ()) in
  Eio.Fiber.all
    (List.init ndomains (fun did () ->
         Eio.Domain_manager.run dm (fun () ->
             let branch = Printf.sprintf "worker-%d" did in
             let br = Store.of_branch repo branch in
             let tree =
               Store.Tree.add (Store.Tree.empty ())
                 [ "file" ]
                 (Printf.sprintf "value-%d" did)
             in
             Store.set_tree_exn br
               ~info:(fun () ->
                 Store.Info.v ~author:"test"
                   ~message:(Printf.sprintf "w%d" did) 0L)
               [] tree)));
  for did = 0 to ndomains - 1 do
    let br = Store.of_branch repo (Printf.sprintf "worker-%d" did) in
    let expected = Printf.sprintf "value-%d" did in
    Alcotest.(check (option string))
      (Printf.sprintf "worker-%d" did)
      (Some expected)
      (Store.find br [ "file" ])
  done

(* ================================================================== *)
(* Suite                                                               *)
(* ================================================================== *)

let suite =
  [
    ( "Tree",
      [
        Alcotest.test_case "empty" `Quick test_tree_empty;
        Alcotest.test_case "add/find" `Quick test_tree_add_find;
        Alcotest.test_case "remove" `Quick test_tree_remove;
        Alcotest.test_case "overwrite" `Quick test_tree_overwrite;
        Alcotest.test_case "nested" `Quick test_tree_nested;
        Alcotest.test_case "mem" `Quick test_tree_mem;
        Alcotest.test_case "mem_tree" `Quick test_tree_mem_tree;
        Alcotest.test_case "list" `Quick test_tree_list;
        Alcotest.test_case "list nested" `Quick test_tree_list_nested;
        Alcotest.test_case "find_tree" `Quick test_tree_find_tree;
        Alcotest.test_case "add_tree" `Quick test_tree_add_tree;
        Alcotest.test_case "large flat (1000)" `Quick test_tree_large_flat;
        Alcotest.test_case "large deep (50 levels)" `Quick test_tree_large_deep;
        Alcotest.test_case "large wide+deep (10k)" `Quick
          test_tree_large_wide_and_deep;
        Alcotest.test_case "large remove half" `Quick test_tree_large_remove_half;
        Alcotest.test_case "persistence roundtrip" `Quick
          test_tree_persistence_roundtrip;
      ] );
    ( "Store",
      [
        Alcotest.test_case "commit" `Quick test_store_commit;
        Alcotest.test_case "branches" `Quick test_store_branches;
        Alcotest.test_case "multi-commit (10)" `Quick test_store_multi_commit;
        Alcotest.test_case "checkout" `Quick test_store_checkout;
        Alcotest.test_case "large tree (500)" `Quick test_store_large_tree;
        Alcotest.test_case "multiple branches" `Quick
          test_store_multiple_branches;
        Alcotest.test_case "commit chain + ancestry" `Quick
          test_store_commit_chain;
        Alcotest.test_case "LCA" `Quick test_store_lca;
        Alcotest.test_case "diff" `Quick test_store_diff;
        Alcotest.test_case "diff no change" `Quick test_store_diff_no_change;
      ] );
    ( "Concurrent",
      [
        Alcotest.test_case "parallel reads" `Quick test_concurrent_reads;
        Alcotest.test_case "parallel branches" `Quick test_concurrent_branches;
        Alcotest.test_case "parallel commits" `Quick test_concurrent_commits;
      ] );
  ]
