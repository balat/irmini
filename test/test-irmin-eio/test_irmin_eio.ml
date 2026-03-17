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

(* --- Tree tests ----------------------------------------------------------- *)

let test_tree_empty () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.empty () in
  let entries = Store.Tree.list tree [] in
  Alcotest.(check int) "empty tree" 0 (List.length entries)

let test_tree_add_find () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.empty () in
  let tree = Store.Tree.add tree [ "a"; "b" ] "hello" in
  let v = Store.Tree.find tree [ "a"; "b" ] in
  Alcotest.(check (option string)) "find" (Some "hello") v

let test_tree_remove () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.empty () in
  let tree = Store.Tree.add tree [ "x" ] "value" in
  let tree = Store.Tree.remove tree [ "x" ] in
  let v = Store.Tree.find tree [ "x" ] in
  Alcotest.(check (option string)) "removed" None v

let test_tree_nested () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.empty () in
  let tree = Store.Tree.add tree [ "a"; "b"; "c" ] "deep" in
  let tree = Store.Tree.add tree [ "a"; "d" ] "sibling" in
  let tree = Store.Tree.add tree [ "root" ] "top" in
  let v1 = Store.Tree.find tree [ "a"; "b"; "c" ] in
  let v2 = Store.Tree.find tree [ "a"; "d" ] in
  let v3 = Store.Tree.find tree [ "root" ] in
  Alcotest.(check (option string)) "deep" (Some "deep") v1;
  Alcotest.(check (option string)) "sibling" (Some "sibling") v2;
  Alcotest.(check (option string)) "top" (Some "top") v3

let test_tree_overwrite () =
  with_repo @@ fun _repo ->
  let tree = Store.Tree.empty () in
  let tree = Store.Tree.add tree [ "k" ] "v1" in
  let tree = Store.Tree.add tree [ "k" ] "v2" in
  let v = Store.Tree.find tree [ "k" ] in
  Alcotest.(check (option string)) "overwritten" (Some "v2") v

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
  let v = Store.Tree.find tree [ "k0500" ] in
  Alcotest.(check (option string)) "spot check" (Some "v500") v

(* --- Store tests ---------------------------------------------------------- *)

let test_store_commit () =
  with_repo @@ fun repo ->
  let store = Store.main repo in
  let tree = Store.Tree.empty () in
  let tree = Store.Tree.add tree [ "file" ] "content" in
  Store.set_tree_exn store ~info [] tree;
  let v = Store.find store [ "file" ] in
  Alcotest.(check (option string)) "committed" (Some "content") v

let test_store_branches () =
  with_repo @@ fun repo ->
  let main = Store.main repo in
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "data" ] "main-val" in
  Store.set_tree_exn main ~info [] tree;
  let br = Store.of_branch repo "feature" in
  let tree2 = Store.Tree.add (Store.Tree.empty ()) [ "data" ] "feature-val" in
  Store.set_tree_exn br ~info [] tree2;
  let v_main = Store.find main [ "data" ] in
  let v_feat = Store.find br [ "data" ] in
  Alcotest.(check (option string)) "main" (Some "main-val") v_main;
  Alcotest.(check (option string)) "feature" (Some "feature-val") v_feat

let test_store_multi_commit () =
  with_repo @@ fun repo ->
  let store = Store.main repo in
  for i = 1 to 10 do
    let tree = Store.get_tree store [] in
    let tree = Store.Tree.add tree [ "counter" ] (string_of_int i) in
    Store.set_tree_exn store ~info [] tree
  done;
  let v = Store.find store [ "counter" ] in
  Alcotest.(check (option string)) "10th commit" (Some "10") v

let test_store_checkout () =
  with_repo @@ fun repo ->
  let store = Store.main repo in
  let tree = Store.Tree.add (Store.Tree.empty ()) [ "x" ] "val" in
  Store.set_tree_exn store ~info [] tree;
  let store2 = Store.main repo in
  let v = Store.find store2 [ "x" ] in
  Alcotest.(check (option string)) "checkout" (Some "val") v

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
  let v = Store.Tree.find tree2 [ "dir-25"; "f250" ] in
  Alcotest.(check (option string)) "large tree" (Some "c250") v

(* --- Concurrent tests (Eio multi-domain) --------------------------------- *)

let test_concurrent_reads () =
  with_repo_env @@ fun env repo ->
  let store = Store.main repo in
  (* Populate *)
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
  (* Read from multiple domains *)
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
  let nerr = Atomic.get errors in
  Alcotest.(check int) "no read errors" 0 nerr

let test_concurrent_branches () =
  with_repo_env @@ fun env repo ->
  let dm = Eio.Stdenv.domain_mgr env in
  let ndomains = min 4 (Domain.recommended_domain_count ()) in
  Eio.Fiber.all
    (List.init ndomains (fun did () ->
         Eio.Domain_manager.run dm (fun () ->
             let branch = Printf.sprintf "branch-%d" did in
             let br = Store.of_branch repo branch in
             for i = 1 to 10 do
               let tree = Store.get_tree br [] in
               let tree =
                 Store.Tree.add tree [ "counter" ] (string_of_int i)
               in
               Store.set_tree_exn br
                 ~info:(fun () ->
                   Store.Info.v ~author:"test" ~message:(string_of_int i) 0L)
                 [] tree
             done)));
  (* Check each branch has its own value *)
  for did = 0 to ndomains - 1 do
    let br = Store.of_branch repo (Printf.sprintf "branch-%d" did) in
    let v = Store.find br [ "counter" ] in
    Alcotest.(check (option string))
      (Printf.sprintf "branch-%d final" did)
      (Some "10") v
  done

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
    ( "Concurrent",
      [
        Alcotest.test_case "parallel reads" `Quick test_concurrent_reads;
        Alcotest.test_case "parallel branches" `Quick test_concurrent_branches;
      ] );
  ]
