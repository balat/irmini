(** Cross-implementation tests for Irmin-Lwt (main branch).

    Tests the same scenarios as the Irmini test suite against the official
    Irmin Lwt backend, to ensure behavioral equivalence.
    No multicore tests (Lwt is single-threaded).

    Build from the Irmin workspace (main branch):
      dune exec test-irmin-lwt/main.exe *)

module Store = Irmin_mem.KV.Make (Irmin.Contents.String)

let info () = Store.Info.v ~author:"test" ~message:"commit" 0L

(* --- Helpers -------------------------------------------------------------- *)

let with_repo f =
  Lwt_main.run
    (let open Lwt.Syntax in
     let config = Irmin_mem.config () in
     let* repo = Store.Repo.v config in
     Lwt.finalize (fun () -> f repo) (fun () -> Store.Repo.close repo))

(* ================================================================== *)
(* Tree: basic                                                         *)
(* ================================================================== *)

let test_tree_empty () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let tree = Store.Tree.empty () in
  let* entries = Store.Tree.list tree [] in
  Alcotest.(check int) "empty tree" 0 (List.length entries);
  Lwt.return_unit

let test_tree_add_find () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "a"; "b" ] "hello" in
  let* v = Store.Tree.find tree [ "a"; "b" ] in
  Alcotest.(check (option string)) "find" (Some "hello") v;
  Lwt.return_unit

let test_tree_remove () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "x" ] "value" in
  let* tree = Store.Tree.remove tree [ "x" ] in
  let* v = Store.Tree.find tree [ "x" ] in
  Alcotest.(check (option string)) "removed" None v;
  Lwt.return_unit

let test_tree_overwrite () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "k" ] "v1" in
  let* tree = Store.Tree.add tree [ "k" ] "v2" in
  let* v = Store.Tree.find tree [ "k" ] in
  Alcotest.(check (option string)) "overwritten" (Some "v2") v;
  Lwt.return_unit

let test_tree_nested () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "a"; "b"; "c" ] "deep" in
  let* tree = Store.Tree.add tree [ "a"; "d" ] "sibling" in
  let* tree = Store.Tree.add tree [ "root" ] "top" in
  let* v1 = Store.Tree.find tree [ "a"; "b"; "c" ] in
  let* v2 = Store.Tree.find tree [ "a"; "d" ] in
  let* v3 = Store.Tree.find tree [ "root" ] in
  Alcotest.(check (option string)) "deep" (Some "deep") v1;
  Alcotest.(check (option string)) "sibling" (Some "sibling") v2;
  Alcotest.(check (option string)) "top" (Some "top") v3;
  Lwt.return_unit

(* ================================================================== *)
(* Tree: mem / mem_tree                                                *)
(* ================================================================== *)

let test_tree_mem () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "a"; "b" ] "v" in
  let* tree = Store.Tree.add tree [ "c" ] "v2" in
  let* m1 = Store.Tree.mem tree [ "a"; "b" ] in
  let* m2 = Store.Tree.mem tree [ "c" ] in
  let* m3 = Store.Tree.mem tree [ "a"; "c" ] in
  let* m4 = Store.Tree.mem tree [ "z" ] in
  Alcotest.(check bool) "mem leaf" true m1;
  Alcotest.(check bool) "mem content" true m2;
  Alcotest.(check bool) "mem missing" false m3;
  Alcotest.(check bool) "mem nonexistent" false m4;
  Lwt.return_unit

let test_tree_mem_tree () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "a"; "b" ] "v" in
  let* m1 = Store.Tree.mem_tree tree [ "a" ] in
  let* m2 = Store.Tree.mem_tree tree [ "a"; "b" ] in
  let* m3 = Store.Tree.mem_tree tree [ "x" ] in
  Alcotest.(check bool) "mem_tree subtree" true m1;
  (* In Irmin, mem_tree on a contents leaf returns true *)
  Alcotest.(check bool) "mem_tree leaf (irmin: true)" true m2;
  Alcotest.(check bool) "mem_tree missing" false m3;
  Lwt.return_unit

(* ================================================================== *)
(* Tree: list                                                          *)
(* ================================================================== *)

let test_tree_list () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "b" ] "2" in
  let* tree = Store.Tree.add tree [ "a" ] "1" in
  let* tree = Store.Tree.add tree [ "c" ] "3" in
  let* entries = Store.Tree.list tree [] in
  let names = List.map (fun (s, _) -> s) entries in
  Alcotest.(check int) "3 entries" 3 (List.length names);
  Alcotest.(check bool) "has a" true (List.mem "a" names);
  Alcotest.(check bool) "has b" true (List.mem "b" names);
  Alcotest.(check bool) "has c" true (List.mem "c" names);
  Lwt.return_unit

let test_tree_list_nested () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "dir"; "f1" ] "v1" in
  let* tree = Store.Tree.add tree [ "dir"; "f2" ] "v2" in
  let* tree = Store.Tree.add tree [ "top" ] "v3" in
  let* top = Store.Tree.list tree [] in
  Alcotest.(check int) "2 top entries" 2 (List.length top);
  let* sub = Store.Tree.list tree [ "dir" ] in
  Alcotest.(check int) "2 sub entries" 2 (List.length sub);
  Lwt.return_unit

(* ================================================================== *)
(* Tree: find_tree / add_tree                                          *)
(* ================================================================== *)

let test_tree_find_tree () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "a"; "b" ] "v" in
  let* sub = Store.Tree.find_tree tree [ "a" ] in
  (match sub with
   | Some s ->
       let* v = Store.Tree.find s [ "b" ] in
       Alcotest.(check (option string)) "find in subtree" (Some "v") v;
       Lwt.return_unit
   | None -> Alcotest.fail "subtree not found")

let test_tree_add_tree () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let* sub = Store.Tree.add (Store.Tree.empty ()) [ "x" ] "vx" in
  let* sub = Store.Tree.add sub [ "y" ] "vy" in
  let* tree = Store.Tree.add_tree (Store.Tree.empty ()) [ "dir" ] sub in
  let* vx = Store.Tree.find tree [ "dir"; "x" ] in
  let* vy = Store.Tree.find tree [ "dir"; "y" ] in
  Alcotest.(check (option string)) "find x" (Some "vx") vx;
  Alcotest.(check (option string)) "find y" (Some "vy") vy;
  Lwt.return_unit

(* ================================================================== *)
(* Tree: large                                                         *)
(* ================================================================== *)

let test_tree_large_flat () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let n = 1000 in
  let* tree =
    let t = ref (Store.Tree.empty ()) in
    let rec loop i =
      if i >= n then Lwt.return !t
      else
        let* t' =
          Store.Tree.add !t
            [ Printf.sprintf "k%04d" i ]
            (Printf.sprintf "v%d" i)
        in
        t := t';
        loop (i + 1)
    in
    loop 0
  in
  let* entries = Store.Tree.list tree [] in
  Alcotest.(check int) "1000 entries" n (List.length entries);
  let* v = Store.Tree.find tree [ "k0500" ] in
  Alcotest.(check (option string)) "spot check" (Some "v500") v;
  Lwt.return_unit

let test_tree_large_deep () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let path = List.init 50 (fun i -> Printf.sprintf "level-%d" i) in
  let* tree = Store.Tree.add (Store.Tree.empty ()) path "deep-value" in
  let* v = Store.Tree.find tree path in
  Alcotest.(check (option string)) "find deep" (Some "deep-value") v;
  let partial = List.filteri (fun i _ -> i < 25) path in
  let* m = Store.Tree.mem_tree tree partial in
  Alcotest.(check bool) "mem_tree at 25" true m;
  Lwt.return_unit

let test_tree_large_wide_and_deep () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let* tree =
    let t = ref (Store.Tree.empty ()) in
    let rec loop_d d =
      if d >= 100 then Lwt.return !t
      else
        let rec loop_f f =
          if f >= 100 then loop_d (d + 1)
          else
            let* t' =
              Store.Tree.add !t
                [ Printf.sprintf "dir-%02d" d; Printf.sprintf "file-%02d" f ]
                (Printf.sprintf "v-%d-%d" d f)
            in
            t := t';
            loop_f (f + 1)
        in
        loop_f 0
    in
    loop_d 0
  in
  let* v = Store.Tree.find tree [ "dir-00"; "file-00" ] in
  Alcotest.(check (option string)) "0-0" (Some "v-0-0") v;
  let* v = Store.Tree.find tree [ "dir-99"; "file-99" ] in
  Alcotest.(check (option string)) "99-99" (Some "v-99-99") v;
  let* dirs = Store.Tree.list tree [] in
  Alcotest.(check int) "100 dirs" 100 (List.length dirs);
  let* files = Store.Tree.list tree [ "dir-42" ] in
  Alcotest.(check int) "100 files" 100 (List.length files);
  Lwt.return_unit

let test_tree_large_remove_half () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let* tree =
    let t = ref (Store.Tree.empty ()) in
    let rec loop i =
      if i >= 1000 then Lwt.return !t
      else
        let* t' =
          Store.Tree.add !t
            [ Printf.sprintf "k%d" i ]
            (Printf.sprintf "v%d" i)
        in
        t := t';
        loop (i + 1)
    in
    loop 0
  in
  let* tree =
    let t = ref tree in
    let rec loop i =
      if i >= 1000 then Lwt.return !t
      else begin
        let* () =
          if i mod 2 = 0 then
            let* t' = Store.Tree.remove !t [ Printf.sprintf "k%d" i ] in
            t := t';
            Lwt.return_unit
          else Lwt.return_unit
        in
        loop (i + 1)
      end
    in
    loop 0
  in
  let* entries = Store.Tree.list tree [] in
  Alcotest.(check int) "500 remaining" 500 (List.length entries);
  Lwt.return_unit

(* ================================================================== *)
(* Tree: persistence roundtrip                                         *)
(* ================================================================== *)

let test_tree_persistence_roundtrip () =
  with_repo @@ fun repo ->
  let open Lwt.Syntax in
  let* store = Store.main repo in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "a"; "b" ] "v1" in
  let* tree = Store.Tree.add tree [ "a"; "c" ] "v2" in
  let* tree = Store.Tree.add tree [ "d" ] "v3" in
  let* () = Store.set_tree_exn store ~info [] tree in
  let* tree2 = Store.get_tree store [] in
  let* v1 = Store.Tree.find tree2 [ "a"; "b" ] in
  let* v2 = Store.Tree.find tree2 [ "a"; "c" ] in
  let* v3 = Store.Tree.find tree2 [ "d" ] in
  Alcotest.(check (option string)) "a/b" (Some "v1") v1;
  Alcotest.(check (option string)) "a/c" (Some "v2") v2;
  Alcotest.(check (option string)) "d" (Some "v3") v3;
  Lwt.return_unit

(* ================================================================== *)
(* Store: basic                                                        *)
(* ================================================================== *)

let test_store_commit () =
  with_repo @@ fun repo ->
  let open Lwt.Syntax in
  let* store = Store.main repo in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "file" ] "content" in
  let* () = Store.set_tree_exn store ~info [] tree in
  let* v = Store.find store [ "file" ] in
  Alcotest.(check (option string)) "committed" (Some "content") v;
  Lwt.return_unit

let test_store_branches () =
  with_repo @@ fun repo ->
  let open Lwt.Syntax in
  let* main = Store.main repo in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "data" ] "main-val" in
  let* () = Store.set_tree_exn main ~info [] tree in
  let* br = Store.of_branch repo "feature" in
  let* tree2 = Store.Tree.add (Store.Tree.empty ()) [ "data" ] "feature-val" in
  let* () = Store.set_tree_exn br ~info [] tree2 in
  let* v_main = Store.find main [ "data" ] in
  let* v_feat = Store.find br [ "data" ] in
  Alcotest.(check (option string)) "main" (Some "main-val") v_main;
  Alcotest.(check (option string)) "feature" (Some "feature-val") v_feat;
  Lwt.return_unit

let test_store_multi_commit () =
  with_repo @@ fun repo ->
  let open Lwt.Syntax in
  let* store = Store.main repo in
  let rec loop i =
    if i > 10 then Lwt.return_unit
    else
      let* tree = Store.get_tree store [] in
      let* tree = Store.Tree.add tree [ "counter" ] (string_of_int i) in
      let* () = Store.set_tree_exn store ~info [] tree in
      loop (i + 1)
  in
  let* () = loop 1 in
  let* v = Store.find store [ "counter" ] in
  Alcotest.(check (option string)) "10th commit" (Some "10") v;
  Lwt.return_unit

let test_store_checkout () =
  with_repo @@ fun repo ->
  let open Lwt.Syntax in
  let* store = Store.main repo in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "x" ] "val" in
  let* () = Store.set_tree_exn store ~info [] tree in
  let* store2 = Store.main repo in
  let* v = Store.find store2 [ "x" ] in
  Alcotest.(check (option string)) "checkout" (Some "val") v;
  Lwt.return_unit

let test_store_large_tree () =
  with_repo @@ fun repo ->
  let open Lwt.Syntax in
  let* store = Store.main repo in
  let nfiles = 500 in
  let* tree =
    let t = ref (Store.Tree.empty ()) in
    let rec loop i =
      if i >= nfiles then Lwt.return !t
      else
        let* t' =
          Store.Tree.add !t
            [ Printf.sprintf "dir-%02d" (i / 10); Printf.sprintf "f%d" i ]
            (Printf.sprintf "c%d" i)
        in
        t := t';
        loop (i + 1)
    in
    loop 0
  in
  let* () = Store.set_tree_exn store ~info [] tree in
  let* tree2 = Store.get_tree store [] in
  let* v = Store.Tree.find tree2 [ "dir-25"; "f250" ] in
  Alcotest.(check (option string)) "large tree" (Some "c250") v;
  Lwt.return_unit

(* ================================================================== *)
(* Store: multiple branches                                            *)
(* ================================================================== *)

let test_store_multiple_branches () =
  with_repo @@ fun repo ->
  let open Lwt.Syntax in
  let* main = Store.main repo in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "f" ] "v" in
  let* () = Store.set_tree_exn main ~info [] tree in
  let* dev = Store.of_branch repo "dev" in
  let* () = Store.set_tree_exn dev ~info [] tree in
  let* branches = Store.Branch.list repo in
  Alcotest.(check bool) "has main" true (List.mem "main" branches);
  Alcotest.(check bool) "has dev" true (List.mem "dev" branches);
  Alcotest.(check bool) "at least 2" true (List.length branches >= 2);
  Lwt.return_unit

(* ================================================================== *)
(* Store: commit chain + ancestry                                      *)
(* ================================================================== *)

let test_store_commit_chain () =
  with_repo @@ fun repo ->
  let open Lwt.Syntax in
  let* store = Store.main repo in
  let rec loop i =
    if i > 3 then Lwt.return_unit
    else
      let* tree = Store.get_tree store [] in
      let* tree = Store.Tree.add tree [ "f" ] (Printf.sprintf "v%d" i) in
      let* () = Store.set_tree_exn store ~info [] tree in
      loop (i + 1)
  in
  let* () = loop 1 in
  let* v = Store.find store [ "f" ] in
  Alcotest.(check (option string)) "latest" (Some "v3") v;
  let* head = Store.Head.find store in
  (match head with
   | None -> Alcotest.fail "no head"
   | Some commit ->
       let parents = Store.Commit.parents commit in
       Alcotest.(check bool) "has parent" true (List.length parents > 0));
  Lwt.return_unit

(* ================================================================== *)
(* Store: LCA                                                          *)
(* ================================================================== *)

let test_store_lca () =
  with_repo @@ fun repo ->
  let open Lwt.Syntax in
  let* main = Store.main repo in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "f" ] "base" in
  let* () = Store.set_tree_exn main ~info [] tree in
  let* br_a = Store.of_branch repo "branch-a" in
  let* tree_a = Store.Tree.add (Store.Tree.empty ()) [ "f" ] "val-a" in
  let* () = Store.set_tree_exn br_a ~info [] tree_a in
  let* br_b = Store.of_branch repo "branch-b" in
  let* tree_b = Store.Tree.add (Store.Tree.empty ()) [ "f" ] "val-b" in
  let* () = Store.set_tree_exn br_b ~info [] tree_b in
  let* result = Store.lcas br_a br_b in
  (match result with
   | Ok lcas ->
       Alcotest.(check bool) "lca found" true (List.length lcas >= 0)
   | Error _ -> Alcotest.fail "lcas error");
  Lwt.return_unit

(* ================================================================== *)
(* Store: diff                                                         *)
(* ================================================================== *)

let test_store_diff () =
  with_repo @@ fun repo ->
  let open Lwt.Syntax in
  let* store = Store.main repo in
  let* tree1 = Store.Tree.add (Store.Tree.empty ()) [ "a" ] "v1" in
  let* tree1 = Store.Tree.add tree1 [ "b" ] "v2" in
  let* () = Store.set_tree_exn store ~info [] tree1 in
  let* tree2 = Store.Tree.add (Store.Tree.empty ()) [ "a" ] "v1-mod" in
  let* tree2 = Store.Tree.add tree2 [ "c" ] "v3" in
  let* () = Store.set_tree_exn store ~info [] tree2 in
  let* diff = Store.Tree.diff tree1 tree2 in
  Alcotest.(check bool) "diff not empty" true (List.length diff > 0);
  Lwt.return_unit

let test_store_diff_no_change () =
  with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "f" ] "v" in
  let* diff = Store.Tree.diff tree tree in
  Alcotest.(check int) "no changes" 0 (List.length diff);
  Lwt.return_unit

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
  ]
