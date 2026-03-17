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
  let open Lwt.Syntax in
  let config = Irmin_mem.config () in
  let* repo = Store.Repo.v config in
  Lwt.finalize
    (fun () -> f repo)
    (fun () -> Store.Repo.close repo)

(* --- Tree tests ----------------------------------------------------------- *)

let test_tree_empty () =
  Lwt_main.run @@ with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let tree = Store.Tree.empty () in
  let* entries = Store.Tree.list tree [] in
  Alcotest.(check int) "empty tree" 0 (List.length entries);
  Lwt.return_unit

let test_tree_add_find () =
  Lwt_main.run @@ with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let tree = Store.Tree.empty () in
  let* tree = Store.Tree.add tree [ "a"; "b" ] "hello" in
  let* v = Store.Tree.find tree [ "a"; "b" ] in
  Alcotest.(check (option string)) "find" (Some "hello") v;
  Lwt.return_unit

let test_tree_remove () =
  Lwt_main.run @@ with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let tree = Store.Tree.empty () in
  let* tree = Store.Tree.add tree [ "x" ] "value" in
  let* tree = Store.Tree.remove tree [ "x" ] in
  let* v = Store.Tree.find tree [ "x" ] in
  Alcotest.(check (option string)) "removed" None v;
  Lwt.return_unit

let test_tree_nested () =
  Lwt_main.run @@ with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let tree = Store.Tree.empty () in
  let* tree = Store.Tree.add tree [ "a"; "b"; "c" ] "deep" in
  let* tree = Store.Tree.add tree [ "a"; "d" ] "sibling" in
  let* tree = Store.Tree.add tree [ "root" ] "top" in
  let* v1 = Store.Tree.find tree [ "a"; "b"; "c" ] in
  let* v2 = Store.Tree.find tree [ "a"; "d" ] in
  let* v3 = Store.Tree.find tree [ "root" ] in
  Alcotest.(check (option string)) "deep" (Some "deep") v1;
  Alcotest.(check (option string)) "sibling" (Some "sibling") v2;
  Alcotest.(check (option string)) "top" (Some "top") v3;
  Lwt.return_unit

let test_tree_overwrite () =
  Lwt_main.run @@ with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let tree = Store.Tree.empty () in
  let* tree = Store.Tree.add tree [ "k" ] "v1" in
  let* tree = Store.Tree.add tree [ "k" ] "v2" in
  let* v = Store.Tree.find tree [ "k" ] in
  Alcotest.(check (option string)) "overwritten" (Some "v2") v;
  Lwt.return_unit

let test_tree_large_flat () =
  Lwt_main.run @@ with_repo @@ fun _repo ->
  let open Lwt.Syntax in
  let n = 1000 in
  let* tree =
    let t = ref (Store.Tree.empty ()) in
    let rec loop i =
      if i >= n then Lwt.return !t
      else
        let* t' = Store.Tree.add !t [ Printf.sprintf "k%04d" i ]
          (Printf.sprintf "v%d" i) in
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

(* --- Store tests ---------------------------------------------------------- *)

let test_store_commit () =
  Lwt_main.run @@ with_repo @@ fun repo ->
  let open Lwt.Syntax in
  let* store = Store.main repo in
  let tree = Store.Tree.empty () in
  let* tree = Store.Tree.add tree [ "file" ] "content" in
  let* () = Store.set_tree_exn store ~info [] tree in
  let* v = Store.find store [ "file" ] in
  Alcotest.(check (option string)) "committed" (Some "content") v;
  Lwt.return_unit

let test_store_branches () =
  Lwt_main.run @@ with_repo @@ fun repo ->
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
  Lwt_main.run @@ with_repo @@ fun repo ->
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
  Lwt_main.run @@ with_repo @@ fun repo ->
  let open Lwt.Syntax in
  let* store = Store.main repo in
  let* tree = Store.Tree.add (Store.Tree.empty ()) [ "x" ] "val" in
  let* () = Store.set_tree_exn store ~info [] tree in
  let* store2 = Store.main repo in
  let* v = Store.find store2 [ "x" ] in
  Alcotest.(check (option string)) "checkout" (Some "val") v;
  Lwt.return_unit

let test_store_large_tree () =
  Lwt_main.run @@ with_repo @@ fun repo ->
  let open Lwt.Syntax in
  let* store = Store.main repo in
  let nfiles = 500 in
  let* tree =
    let t = ref (Store.Tree.empty ()) in
    let rec loop i =
      if i >= nfiles then Lwt.return !t
      else
        let* t' = Store.Tree.add !t
          [ Printf.sprintf "dir-%02d" (i / 10); Printf.sprintf "f%d" i ]
          (Printf.sprintf "c%d" i) in
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

(* --- Suite ---------------------------------------------------------------- *)

let suite =
  [
    ( "Tree",
      [
        Alcotest.test_case "empty" `Quick test_tree_empty;
        Alcotest.test_case "add/find" `Quick test_tree_add_find;
        Alcotest.test_case "remove" `Quick test_tree_remove;
        Alcotest.test_case "nested" `Quick test_tree_nested;
        Alcotest.test_case "overwrite" `Quick test_tree_overwrite;
        Alcotest.test_case "large flat (1000)" `Quick test_tree_large_flat;
      ] );
    ( "Store",
      [
        Alcotest.test_case "commit" `Quick test_store_commit;
        Alcotest.test_case "branches" `Quick test_store_branches;
        Alcotest.test_case "multi-commit (10)" `Quick test_store_multi_commit;
        Alcotest.test_case "checkout" `Quick test_store_checkout;
        Alcotest.test_case "large tree (500)" `Quick test_store_large_tree;
      ] );
  ]
