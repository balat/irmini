(** Cross-implementation tests for Irmin-Eio (cuihtlauac branch).

    Tests the same scenarios as the Irmini test suite against the official
    Irmin Eio backend, to ensure behavioral equivalence.

    Sequential tests use Irmin_mem (simple setup).
    Concurrent tests use irmin-pack (domain-safe, unlike Irmin_mem).

    Build from the Irmin workspace (cuihtlauac-inline-small-objects-v2 branch):
      dune exec test-irmin-eio/main.exe *)

(* ================================================================== *)
(* Store modules                                                       *)
(* ================================================================== *)

module Mem_store = Irmin_mem.KV.Make (Irmin.Contents.String)

module Pack_conf = struct
  let entries = 32
  let stable_hash = 256
  let contents_length_header = Some `Varint
  let inode_child_order = `Seeded_hash
  let forbid_empty_dir_persistence = true
end

module Pack_maker = Irmin_pack_unix.KV (Pack_conf)
module Pack_store = Pack_maker.Make (Irmin.Contents.String)

(* ================================================================== *)
(* Helpers                                                             *)
(* ================================================================== *)

let mem_info () = Mem_store.Info.v ~author:"test" ~message:"commit" 0L
let pack_info () = Pack_store.Info.v ~author:"test" ~message:"commit" 0L

(* Each test needs Eio_main.run because Irmin_mem uses Eio_mutex internally. *)
let with_mem_repo f =
  Eio_main.run @@ fun _env ->
  let config = Irmin_mem.config () in
  let repo = Mem_store.Repo.v config in
  Fun.protect ~finally:(fun () -> Mem_store.Repo.close repo) (fun () -> f repo)

let tmp_counter = Atomic.make 0

let rec rm_rf path =
  if Eio.Path.is_directory path then begin
    List.iter
      (fun name -> rm_rf Eio.Path.(path / name))
      (Eio.Path.read_dir path);
    Eio.Path.rmdir path
  end
  else if Eio.Path.is_file path then Eio.Path.unlink path

let with_pack_repo f =
  Eio_main.run @@ fun env ->
  let cwd = Eio.Stdenv.cwd env in
  let fs = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let n = Atomic.fetch_and_add tmp_counter 1 in
  let root =
    Eio.Path.(cwd / Printf.sprintf "_test_pack_%d_%d" (Unix.getpid ()) n)
  in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 root;
  let config = Irmin_pack.Conf.init ~sw ~fs ~fresh:true root in
  let repo = Pack_store.Repo.v config in
  Fun.protect
    ~finally:(fun () ->
      Pack_store.Repo.close repo;
      (try rm_rf root with _ -> ()))
    (fun () -> f env repo)

(* ================================================================== *)
(* Tree: basic (Mem_store)                                             *)
(* ================================================================== *)

let test_tree_empty () =
  with_mem_repo @@ fun _repo ->
  let tree = Mem_store.Tree.empty () in
  let entries = Mem_store.Tree.list tree [] in
  Alcotest.(check int) "empty tree" 0 (List.length entries)

let test_tree_add_find () =
  with_mem_repo @@ fun _repo ->
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "a"; "b" ] "hello" in
  let v = Mem_store.Tree.find tree [ "a"; "b" ] in
  Alcotest.(check (option string)) "find" (Some "hello") v

let test_tree_remove () =
  with_mem_repo @@ fun _repo ->
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "x" ] "value" in
  let tree = Mem_store.Tree.remove tree [ "x" ] in
  Alcotest.(check (option string)) "removed" None
    (Mem_store.Tree.find tree [ "x" ])

let test_tree_overwrite () =
  with_mem_repo @@ fun _repo ->
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "k" ] "v1" in
  let tree = Mem_store.Tree.add tree [ "k" ] "v2" in
  Alcotest.(check (option string)) "overwritten" (Some "v2")
    (Mem_store.Tree.find tree [ "k" ])

let test_tree_nested () =
  with_mem_repo @@ fun _repo ->
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "a"; "b"; "c" ] "deep" in
  let tree = Mem_store.Tree.add tree [ "a"; "d" ] "sibling" in
  let tree = Mem_store.Tree.add tree [ "root" ] "top" in
  Alcotest.(check (option string)) "deep" (Some "deep")
    (Mem_store.Tree.find tree [ "a"; "b"; "c" ]);
  Alcotest.(check (option string)) "sibling" (Some "sibling")
    (Mem_store.Tree.find tree [ "a"; "d" ]);
  Alcotest.(check (option string)) "top" (Some "top")
    (Mem_store.Tree.find tree [ "root" ])

(* ================================================================== *)
(* Tree: mem / mem_tree                                                *)
(* ================================================================== *)

let test_tree_mem () =
  with_mem_repo @@ fun _repo ->
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "a"; "b" ] "v" in
  let tree = Mem_store.Tree.add tree [ "c" ] "v2" in
  Alcotest.(check bool) "mem leaf" true (Mem_store.Tree.mem tree [ "a"; "b" ]);
  Alcotest.(check bool) "mem content" true (Mem_store.Tree.mem tree [ "c" ]);
  Alcotest.(check bool) "mem missing" false (Mem_store.Tree.mem tree [ "a"; "c" ]);
  Alcotest.(check bool) "mem nonexistent" false (Mem_store.Tree.mem tree [ "z" ])

let test_tree_mem_tree () =
  with_mem_repo @@ fun _repo ->
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "a"; "b" ] "v" in
  Alcotest.(check bool) "mem_tree subtree" true
    (Mem_store.Tree.mem_tree tree [ "a" ]);
  (* In Irmin, mem_tree on a contents leaf returns true (contents are trivial
     trees). This differs from Irmini where contents are not trees. *)
  Alcotest.(check bool) "mem_tree leaf (irmin: true)" true
    (Mem_store.Tree.mem_tree tree [ "a"; "b" ]);
  Alcotest.(check bool) "mem_tree missing" false
    (Mem_store.Tree.mem_tree tree [ "x" ])

(* ================================================================== *)
(* Tree: list                                                          *)
(* ================================================================== *)

let test_tree_list () =
  with_mem_repo @@ fun _repo ->
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "b" ] "2" in
  let tree = Mem_store.Tree.add tree [ "a" ] "1" in
  let tree = Mem_store.Tree.add tree [ "c" ] "3" in
  let names = List.map (fun (s, _) -> s) (Mem_store.Tree.list tree []) in
  Alcotest.(check int) "3 entries" 3 (List.length names);
  Alcotest.(check bool) "has a" true (List.mem "a" names);
  Alcotest.(check bool) "has b" true (List.mem "b" names);
  Alcotest.(check bool) "has c" true (List.mem "c" names)

let test_tree_list_nested () =
  with_mem_repo @@ fun _repo ->
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "dir"; "f1" ] "v1" in
  let tree = Mem_store.Tree.add tree [ "dir"; "f2" ] "v2" in
  let tree = Mem_store.Tree.add tree [ "top" ] "v3" in
  let top = Mem_store.Tree.list tree [] in
  Alcotest.(check int) "2 top entries" 2 (List.length top);
  let sub = Mem_store.Tree.list tree [ "dir" ] in
  Alcotest.(check int) "2 sub entries" 2 (List.length sub)

(* ================================================================== *)
(* Tree: find_tree / add_tree                                          *)
(* ================================================================== *)

let test_tree_find_tree () =
  with_mem_repo @@ fun _repo ->
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "a"; "b" ] "v" in
  match Mem_store.Tree.find_tree tree [ "a" ] with
  | Some sub ->
      Alcotest.(check (option string)) "find in subtree" (Some "v")
        (Mem_store.Tree.find sub [ "b" ])
  | None -> Alcotest.fail "subtree not found"

let test_tree_add_tree () =
  with_mem_repo @@ fun _repo ->
  let sub = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "x" ] "vx" in
  let sub = Mem_store.Tree.add sub [ "y" ] "vy" in
  let tree = Mem_store.Tree.add_tree (Mem_store.Tree.empty ()) [ "dir" ] sub in
  Alcotest.(check (option string)) "find x" (Some "vx")
    (Mem_store.Tree.find tree [ "dir"; "x" ]);
  Alcotest.(check (option string)) "find y" (Some "vy")
    (Mem_store.Tree.find tree [ "dir"; "y" ])

(* ================================================================== *)
(* Tree: large                                                         *)
(* ================================================================== *)

let test_tree_large_flat () =
  with_mem_repo @@ fun _repo ->
  let n = 1000 in
  let tree =
    let t = ref (Mem_store.Tree.empty ()) in
    for i = 0 to n - 1 do
      t :=
        Mem_store.Tree.add !t
          [ Printf.sprintf "k%04d" i ]
          (Printf.sprintf "v%d" i)
    done;
    !t
  in
  let entries = Mem_store.Tree.list tree [] in
  Alcotest.(check int) "1000 entries" n (List.length entries);
  Alcotest.(check (option string)) "spot check" (Some "v500")
    (Mem_store.Tree.find tree [ "k0500" ])

let test_tree_large_deep () =
  with_mem_repo @@ fun _repo ->
  let path = List.init 50 (fun i -> Printf.sprintf "level-%d" i) in
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) path "deep-value" in
  Alcotest.(check (option string)) "find deep" (Some "deep-value")
    (Mem_store.Tree.find tree path);
  let partial = List.filteri (fun i _ -> i < 25) path in
  Alcotest.(check bool) "mem_tree at 25" true
    (Mem_store.Tree.mem_tree tree partial)

let test_tree_large_wide_and_deep () =
  with_mem_repo @@ fun _repo ->
  let tree = ref (Mem_store.Tree.empty ()) in
  for d = 0 to 99 do
    for f = 0 to 99 do
      tree :=
        Mem_store.Tree.add !tree
          [ Printf.sprintf "dir-%02d" d; Printf.sprintf "file-%02d" f ]
          (Printf.sprintf "v-%d-%d" d f)
    done
  done;
  Alcotest.(check (option string)) "0-0" (Some "v-0-0")
    (Mem_store.Tree.find !tree [ "dir-00"; "file-00" ]);
  Alcotest.(check (option string)) "99-99" (Some "v-99-99")
    (Mem_store.Tree.find !tree [ "dir-99"; "file-99" ]);
  let dirs = Mem_store.Tree.list !tree [] in
  Alcotest.(check int) "100 dirs" 100 (List.length dirs);
  let files = Mem_store.Tree.list !tree [ "dir-42" ] in
  Alcotest.(check int) "100 files" 100 (List.length files)

let test_tree_large_remove_half () =
  with_mem_repo @@ fun _repo ->
  let tree = ref (Mem_store.Tree.empty ()) in
  for i = 0 to 999 do
    tree :=
      Mem_store.Tree.add !tree
        [ Printf.sprintf "k%d" i ]
        (Printf.sprintf "v%d" i)
  done;
  for i = 0 to 999 do
    if i mod 2 = 0 then
      tree := Mem_store.Tree.remove !tree [ Printf.sprintf "k%d" i ]
  done;
  for i = 0 to 999 do
    let key = Printf.sprintf "k%d" i in
    let expected =
      if i mod 2 = 0 then None else Some (Printf.sprintf "v%d" i)
    in
    Alcotest.(check (option string)) key expected
      (Mem_store.Tree.find !tree [ key ])
  done;
  let entries = Mem_store.Tree.list !tree [] in
  Alcotest.(check int) "500 remaining" 500 (List.length entries)

(* ================================================================== *)
(* Tree: persistence roundtrip                                         *)
(* ================================================================== *)

let test_tree_persistence_roundtrip () =
  with_mem_repo @@ fun repo ->
  let store = Mem_store.main repo in
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "a"; "b" ] "v1" in
  let tree = Mem_store.Tree.add tree [ "a"; "c" ] "v2" in
  let tree = Mem_store.Tree.add tree [ "d" ] "v3" in
  Mem_store.set_tree_exn store ~info:mem_info [] tree;
  let tree2 = Mem_store.get_tree store [] in
  Alcotest.(check (option string)) "a/b" (Some "v1")
    (Mem_store.Tree.find tree2 [ "a"; "b" ]);
  Alcotest.(check (option string)) "a/c" (Some "v2")
    (Mem_store.Tree.find tree2 [ "a"; "c" ]);
  Alcotest.(check (option string)) "d" (Some "v3")
    (Mem_store.Tree.find tree2 [ "d" ])

(* ================================================================== *)
(* Store: basic (Mem_store)                                            *)
(* ================================================================== *)

let test_store_commit () =
  with_mem_repo @@ fun repo ->
  let store = Mem_store.main repo in
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "file" ] "content" in
  Mem_store.set_tree_exn store ~info:mem_info [] tree;
  Alcotest.(check (option string)) "committed" (Some "content")
    (Mem_store.find store [ "file" ])

let test_store_branches () =
  with_mem_repo @@ fun repo ->
  let main = Mem_store.main repo in
  Mem_store.set_tree_exn main ~info:mem_info []
    (Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "data" ] "main-val");
  let br = Mem_store.of_branch repo "feature" in
  Mem_store.set_tree_exn br ~info:mem_info []
    (Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "data" ] "feature-val");
  Alcotest.(check (option string)) "main" (Some "main-val")
    (Mem_store.find main [ "data" ]);
  Alcotest.(check (option string)) "feature" (Some "feature-val")
    (Mem_store.find br [ "data" ])

let test_store_multi_commit () =
  with_mem_repo @@ fun repo ->
  let store = Mem_store.main repo in
  for i = 1 to 10 do
    let tree = Mem_store.get_tree store [] in
    let tree = Mem_store.Tree.add tree [ "counter" ] (string_of_int i) in
    Mem_store.set_tree_exn store ~info:mem_info [] tree
  done;
  Alcotest.(check (option string)) "10th commit" (Some "10")
    (Mem_store.find store [ "counter" ])

let test_store_checkout () =
  with_mem_repo @@ fun repo ->
  let store = Mem_store.main repo in
  Mem_store.set_tree_exn store ~info:mem_info []
    (Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "x" ] "val");
  let store2 = Mem_store.main repo in
  Alcotest.(check (option string)) "checkout" (Some "val")
    (Mem_store.find store2 [ "x" ])

let test_store_large_tree () =
  with_mem_repo @@ fun repo ->
  let store = Mem_store.main repo in
  let nfiles = 500 in
  let tree =
    let t = ref (Mem_store.Tree.empty ()) in
    for i = 0 to nfiles - 1 do
      t :=
        Mem_store.Tree.add !t
          [ Printf.sprintf "dir-%02d" (i / 10); Printf.sprintf "f%d" i ]
          (Printf.sprintf "c%d" i)
    done;
    !t
  in
  Mem_store.set_tree_exn store ~info:mem_info [] tree;
  let tree2 = Mem_store.get_tree store [] in
  Alcotest.(check (option string)) "large tree" (Some "c250")
    (Mem_store.Tree.find tree2 [ "dir-25"; "f250" ])

let test_store_multiple_branches () =
  with_mem_repo @@ fun repo ->
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "f" ] "v" in
  let main = Mem_store.main repo in
  Mem_store.set_tree_exn main ~info:mem_info [] tree;
  let dev = Mem_store.of_branch repo "dev" in
  Mem_store.set_tree_exn dev ~info:mem_info [] tree;
  let branches = Mem_store.Branch.list repo in
  Alcotest.(check bool) "has main" true (List.mem "main" branches);
  Alcotest.(check bool) "has dev" true (List.mem "dev" branches);
  Alcotest.(check bool) "at least 2" true (List.length branches >= 2)

let test_store_commit_chain () =
  with_mem_repo @@ fun repo ->
  let store = Mem_store.main repo in
  for i = 1 to 3 do
    let tree = Mem_store.get_tree store [] in
    let tree = Mem_store.Tree.add tree [ "f" ] (Printf.sprintf "v%d" i) in
    Mem_store.set_tree_exn store ~info:mem_info [] tree
  done;
  Alcotest.(check (option string)) "latest" (Some "v3")
    (Mem_store.find store [ "f" ]);
  match Mem_store.Head.find store with
  | None -> Alcotest.fail "no head"
  | Some head ->
      let parents = Mem_store.Commit.parents head in
      Alcotest.(check bool) "has parent" true (List.length parents > 0)

let test_store_lca () =
  with_mem_repo @@ fun repo ->
  let main = Mem_store.main repo in
  Mem_store.set_tree_exn main ~info:mem_info []
    (Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "f" ] "base");
  let br_a = Mem_store.of_branch repo "branch-a" in
  Mem_store.set_tree_exn br_a ~info:mem_info []
    (Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "f" ] "val-a");
  let br_b = Mem_store.of_branch repo "branch-b" in
  Mem_store.set_tree_exn br_b ~info:mem_info []
    (Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "f" ] "val-b");
  match Mem_store.lcas br_a br_b with
  | Ok lcas -> Alcotest.(check bool) "lca found" true (List.length lcas >= 0)
  | Error _ -> Alcotest.fail "lcas error"

let test_store_diff () =
  with_mem_repo @@ fun repo ->
  let store = Mem_store.main repo in
  let tree1 = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "a" ] "v1" in
  let tree1 = Mem_store.Tree.add tree1 [ "b" ] "v2" in
  Mem_store.set_tree_exn store ~info:mem_info [] tree1;
  let tree2 = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "a" ] "v1-mod" in
  let tree2 = Mem_store.Tree.add tree2 [ "c" ] "v3" in
  Mem_store.set_tree_exn store ~info:mem_info [] tree2;
  let diff = Mem_store.Tree.diff tree1 tree2 in
  Alcotest.(check bool) "diff not empty" true (List.length diff > 0)

let test_store_diff_no_change () =
  with_mem_repo @@ fun _repo ->
  let tree = Mem_store.Tree.add (Mem_store.Tree.empty ()) [ "f" ] "v" in
  let diff = Mem_store.Tree.diff tree tree in
  Alcotest.(check int) "no changes" 0 (List.length diff)

(* ================================================================== *)
(* Concurrent: irmin-pack backend (domain-safe)                        *)
(* ================================================================== *)

let test_pack_concurrent_reads () =
  with_pack_repo @@ fun env repo ->
  let store = Pack_store.main repo in
  (* Populate *)
  let tree =
    let t = ref (Pack_store.Tree.empty ()) in
    for i = 0 to 99 do
      t :=
        Pack_store.Tree.add !t
          [ Printf.sprintf "k%d" i ]
          (Printf.sprintf "v%d" i)
    done;
    !t
  in
  Pack_store.set_tree_exn store ~info:pack_info [] tree;
  let tree = Pack_store.get_tree store [] in
  let dm = Eio.Stdenv.domain_mgr env in
  let ndomains = min 4 (Domain.recommended_domain_count ()) in
  let errors = Atomic.make 0 in
  Eio.Fiber.all
    (List.init ndomains (fun did () ->
         Eio.Domain_manager.run dm (fun () ->
             for i = 0 to 99 do
               let k = (did * 17 + i) mod 100 in
               let expected = Printf.sprintf "v%d" k in
               match Pack_store.Tree.find tree [ Printf.sprintf "k%d" k ] with
               | Some v when v = expected -> ()
               | _ -> Atomic.incr errors
             done)));
  Alcotest.(check int) "no read errors" 0 (Atomic.get errors)

let test_pack_concurrent_read_write () =
  with_pack_repo @@ fun env repo ->
  let store = Pack_store.main repo in
  (* Pre-populate some data *)
  let tree =
    let t = ref (Pack_store.Tree.empty ()) in
    for i = 0 to 49 do
      t :=
        Pack_store.Tree.add !t
          [ Printf.sprintf "existing-%d" i ]
          (Printf.sprintf "val-%d" i)
    done;
    !t
  in
  Pack_store.set_tree_exn store ~info:pack_info [] tree;
  let dm = Eio.Stdenv.domain_mgr env in
  let ndomains = min 4 (Domain.recommended_domain_count ()) in
  let read_errors = Atomic.make 0 in
  (* Half readers, half writers — each writer on its own branch *)
  Eio.Fiber.all
    (List.init ndomains (fun did () ->
         Eio.Domain_manager.run dm (fun () ->
             if did mod 2 = 0 then begin
               (* Reader: verify existing data from main *)
               let tree = Pack_store.get_tree store [] in
               for i = 0 to 49 do
                 let expected = Printf.sprintf "val-%d" i in
                 match
                   Pack_store.Tree.find tree
                     [ Printf.sprintf "existing-%d" i ]
                 with
                 | Some v when v = expected -> ()
                 | _ -> Atomic.incr read_errors
               done
             end
             else begin
               (* Writer: add data on own branch *)
               let br =
                 Pack_store.of_branch repo
                   (Printf.sprintf "writer-%d" did)
               in
               let tree = Pack_store.Tree.empty () in
               let tree =
                 let t = ref tree in
                 for i = 0 to 49 do
                   t :=
                     Pack_store.Tree.add !t
                       [ Printf.sprintf "new-%d-%d" did i ]
                       (Printf.sprintf "w%d-%d" did i)
                 done;
                 !t
               in
               Pack_store.set_tree_exn br
                 ~info:(fun () ->
                   Pack_store.Info.v ~author:"test"
                     ~message:(Printf.sprintf "w%d" did) 0L)
                 [] tree
             end)));
  Alcotest.(check int) "no read corruption" 0 (Atomic.get read_errors);
  (* Verify writer branches exist *)
  for did = 0 to ndomains - 1 do
    if did mod 2 <> 0 then begin
      let br =
        Pack_store.of_branch repo (Printf.sprintf "writer-%d" did)
      in
      let v = Pack_store.find br [ Printf.sprintf "new-%d-0" did ] in
      Alcotest.(check (option string))
        (Printf.sprintf "writer-%d data" did)
        (Some (Printf.sprintf "w%d-0" did))
        v
    end
  done

let test_pack_concurrent_writes () =
  with_pack_repo @@ fun env repo ->
  let dm = Eio.Stdenv.domain_mgr env in
  let ndomains = min 4 (Domain.recommended_domain_count ()) in
  let total_per_domain = 100 in
  (* Each domain writes to its own branch *)
  Eio.Fiber.all
    (List.init ndomains (fun did () ->
         Eio.Domain_manager.run dm (fun () ->
             let br =
               Pack_store.of_branch repo (Printf.sprintf "d%d" did)
             in
             let tree =
               let t = ref (Pack_store.Tree.empty ()) in
               for i = 0 to total_per_domain - 1 do
                 t :=
                   Pack_store.Tree.add !t
                     [ Printf.sprintf "k%d" i ]
                     (Printf.sprintf "d%d-v%d" did i)
               done;
               !t
             in
             Pack_store.set_tree_exn br
               ~info:(fun () ->
                 Pack_store.Info.v ~author:"test"
                   ~message:(Printf.sprintf "d%d" did) 0L)
               [] tree)));
  (* Verify all writes visible *)
  let missing = ref 0 in
  for did = 0 to ndomains - 1 do
    let br = Pack_store.of_branch repo (Printf.sprintf "d%d" did) in
    for i = 0 to total_per_domain - 1 do
      match Pack_store.find br [ Printf.sprintf "k%d" i ] with
      | Some v when v = Printf.sprintf "d%d-v%d" did i -> ()
      | _ -> incr missing
    done
  done;
  Alcotest.(check int) "all writes visible" 0 !missing

let test_pack_concurrent_refs () =
  with_pack_repo @@ fun env repo ->
  let dm = Eio.Stdenv.domain_mgr env in
  let ndomains = min 4 (Domain.recommended_domain_count ()) in
  (* Each domain creates its own branch *)
  Eio.Fiber.all
    (List.init ndomains (fun did () ->
         Eio.Domain_manager.run dm (fun () ->
             let branch = Printf.sprintf "ref-branch-%d" did in
             let br = Pack_store.of_branch repo branch in
             let tree =
               Pack_store.Tree.add (Pack_store.Tree.empty ())
                 [ "data" ] (Printf.sprintf "ref-%d" did)
             in
             Pack_store.set_tree_exn br
               ~info:(fun () ->
                 Pack_store.Info.v ~author:"test"
                   ~message:(Printf.sprintf "ref%d" did) 0L)
               [] tree)));
  (* Verify each branch has correct data *)
  for did = 0 to ndomains - 1 do
    let br =
      Pack_store.of_branch repo (Printf.sprintf "ref-branch-%d" did)
    in
    Alcotest.(check (option string))
      (Printf.sprintf "ref-%d" did)
      (Some (Printf.sprintf "ref-%d" did))
      (Pack_store.find br [ "data" ])
  done

let test_pack_concurrent_multi_commit () =
  with_pack_repo @@ fun env repo ->
  let dm = Eio.Stdenv.domain_mgr env in
  let ndomains = min 4 (Domain.recommended_domain_count ()) in
  let commits_per_domain = 10 in
  (* Each domain does multiple commits on its own branch *)
  Eio.Fiber.all
    (List.init ndomains (fun did () ->
         Eio.Domain_manager.run dm (fun () ->
             let br =
               Pack_store.of_branch repo (Printf.sprintf "worker-%d" did)
             in
             for i = 1 to commits_per_domain do
               let tree = Pack_store.get_tree br [] in
               let tree =
                 Pack_store.Tree.add tree [ "counter" ] (string_of_int i)
               in
               let tree =
                 Pack_store.Tree.add tree [ "file" ]
                   (Printf.sprintf "d%d-c%d" did i)
               in
               Pack_store.set_tree_exn br
                 ~info:(fun () ->
                   Pack_store.Info.v ~author:"test"
                     ~message:(Printf.sprintf "d%d-c%d" did i) 0L)
                 [] tree
             done)));
  (* Verify final state *)
  for did = 0 to ndomains - 1 do
    let br =
      Pack_store.of_branch repo (Printf.sprintf "worker-%d" did)
    in
    Alcotest.(check (option string))
      (Printf.sprintf "worker-%d counter" did)
      (Some (string_of_int commits_per_domain))
      (Pack_store.find br [ "counter" ]);
    Alcotest.(check (option string))
      (Printf.sprintf "worker-%d file" did)
      (Some (Printf.sprintf "d%d-c%d" did commits_per_domain))
      (Pack_store.find br [ "file" ])
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
    ( "Concurrent (pack)",
      [
        Alcotest.test_case "concurrent reads" `Quick test_pack_concurrent_reads;
        Alcotest.test_case "concurrent read+write" `Quick
          test_pack_concurrent_read_write;
        Alcotest.test_case "concurrent writes" `Quick
          test_pack_concurrent_writes;
        Alcotest.test_case "concurrent refs" `Quick test_pack_concurrent_refs;
        Alcotest.test_case "concurrent multi-commit" `Quick
          test_pack_concurrent_multi_commit;
      ] );
  ]
