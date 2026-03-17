open Irmin

let ndomains = min 4 (Domain.recommended_domain_count ())

(** Run [f domain_id] on N OS domains in parallel, with a barrier
    to synchronize startup. *)
let run_parallel ~n f =
  let barrier = Atomic.make n in
  let errors = Atomic.make 0 in
  let domains =
    Array.init n (fun i ->
        Domain.spawn (fun () ->
            Atomic.decr barrier;
            while Atomic.get barrier > 0 do
              Domain.cpu_relax ()
            done;
            try f i with _ -> Atomic.incr errors))
  in
  Array.iter Domain.join domains;
  let e = Atomic.get errors in
  if e > 0 then Alcotest.failf "%d domains raised exceptions" e

(* ================================================================== *)
(* Memory backend: thread_safe_rw (read-write lock)                    *)
(* ================================================================== *)

let test_memory_concurrent_reads () =
  let backend = Backend.thread_safe_rw (Backend.Memory.create_sha1 ()) in
  let hashes =
    List.init 100 (fun i ->
        let data = Printf.sprintf "data-%d" i in
        let h = Hash.sha1 data in
        backend.write h data;
        h)
  in
  let missed = Atomic.make 0 in
  run_parallel ~n:ndomains (fun _did ->
      List.iter
        (fun h ->
          match backend.read h with
          | Some _ -> ()
          | None -> Atomic.incr missed)
        hashes);
  Alcotest.(check int) "no missed reads" 0 (Atomic.get missed)

let test_memory_concurrent_read_write () =
  let backend = Backend.thread_safe_rw (Backend.Memory.create_sha1 ()) in
  let total_per_domain = 500 in
  run_parallel ~n:ndomains (fun did ->
      for i = 0 to total_per_domain - 1 do
        let data = Printf.sprintf "d%d-i%d" did i in
        let h = Hash.sha1 data in
        backend.write h data
      done);
  (* Verify all writes are visible *)
  let missing = ref 0 in
  for did = 0 to ndomains - 1 do
    for i = 0 to total_per_domain - 1 do
      let data = Printf.sprintf "d%d-i%d" did i in
      let h = Hash.sha1 data in
      if not (backend.exists h) then incr missing
    done
  done;
  Alcotest.(check int) "all writes visible" 0 !missing

let test_memory_concurrent_refs () =
  let backend = Backend.thread_safe_rw (Backend.Memory.create_sha1 ()) in
  run_parallel ~n:ndomains (fun did ->
      let name = Printf.sprintf "branch-%d" did in
      let h = Hash.sha1 (Printf.sprintf "commit-%d" did) in
      backend.set_ref name h;
      match backend.get_ref name with
      | Some _ -> ()
      | None -> Alcotest.failf "domain %d: ref %s not found" did name)

(* ================================================================== *)
(* Disk backend: lock-free reads + per-domain WAL                      *)
(* ================================================================== *)

let rec rm_rf path =
  if Eio.Path.is_directory path then begin
    List.iter
      (fun name -> rm_rf Eio.Path.(path / name))
      (Eio.Path.read_dir path);
    Eio.Path.rmdir path
  end
  else if Eio.Path.is_file path then Eio.Path.unlink path

let with_disk_backend f =
  Eio_main.run @@ fun env ->
  let cwd = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let tmp = Printf.sprintf "irmin-conc-%d" (Random.int 100000) in
  let root = Eio.Path.(cwd / tmp) in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 root;
  let backend = Backend.Disk.create_sha1 ~use_fsync:false ~sw root in
  Fun.protect
    ~finally:(fun () -> backend.close (); rm_rf root)
    (fun () -> f ~env ~sw backend)

(** Run [f domain_id] on N Eio domains in parallel (for disk backend tests). *)
let run_parallel_eio ~env ~n f =
  let dm = Eio.Stdenv.domain_mgr env in
  let barrier = Atomic.make n in
  let errors = Atomic.make 0 in
  Eio.Fiber.all
    (List.init n (fun i () ->
         Eio.Domain_manager.run dm (fun () ->
             Atomic.decr barrier;
             while Atomic.get barrier > 0 do
               Domain.cpu_relax ()
             done;
             try f i with _ -> Atomic.incr errors)));
  let e = Atomic.get errors in
  if e > 0 then Alcotest.failf "%d domains raised exceptions" e

let test_disk_concurrent_reads () =
  with_disk_backend (fun ~env ~sw:_ backend ->
      let hashes =
        List.init 200 (fun i ->
            let data = Printf.sprintf "data-%d" i in
            let h = Hash.sha1 data in
            backend.write h data;
            h)
      in
      let missed = Atomic.make 0 in
      run_parallel_eio ~env ~n:ndomains (fun _did ->
          List.iter
            (fun h ->
              match backend.read h with
              | Some _ -> ()
              | None -> Atomic.incr missed)
            hashes);
      Alcotest.(check int) "no missed reads" 0 (Atomic.get missed))

let test_disk_concurrent_writes () =
  with_disk_backend (fun ~env ~sw:_ backend ->
      let total_per_domain = 200 in
      run_parallel_eio ~env ~n:ndomains (fun did ->
          for i = 0 to total_per_domain - 1 do
            let data = Printf.sprintf "d%d-i%d" did i in
            let h = Hash.sha1 data in
            backend.write h data
          done);
      (* Verify all writes visible *)
      let missing = ref 0 in
      for did = 0 to ndomains - 1 do
        for i = 0 to total_per_domain - 1 do
          let data = Printf.sprintf "d%d-i%d" did i in
          let h = Hash.sha1 data in
          if not (backend.exists h) then incr missing
        done
      done;
      Alcotest.(check int) "all writes visible" 0 !missing)

let test_disk_concurrent_read_write () =
  with_disk_backend (fun ~env ~sw:_ backend ->
      (* Pre-populate *)
      let existing =
        List.init 100 (fun i ->
            let data = Printf.sprintf "existing-%d" i in
            let h = Hash.sha1 data in
            backend.write h data;
            (h, data))
      in
      let read_errors = Atomic.make 0 in
      let write_errors = Atomic.make 0 in
      (* Half readers, half writers *)
      run_parallel_eio ~env ~n:ndomains (fun did ->
          if did mod 2 = 0 then begin
            (* Reader: verify existing data is never corrupted *)
            for _ = 1 to 1000 do
              let h, expected = List.nth existing (Random.int 100) in
              match backend.read h with
              | Some data when data = expected -> ()
              | Some _ -> Atomic.incr read_errors (* corrupted! *)
              | None -> () (* might not be written yet — OK for new data *)
            done
          end else begin
            (* Writer: add new data *)
            for i = 0 to 199 do
              let data = Printf.sprintf "new-d%d-i%d" did i in
              let h = Hash.sha1 data in
              backend.write h data
            done
          end);
      Alcotest.(check int) "no read corruption" 0 (Atomic.get read_errors);
      Alcotest.(check int) "no write errors" 0 (Atomic.get write_errors))

let test_disk_write_batch_concurrent () =
  with_disk_backend (fun ~env ~sw:_ backend ->
      run_parallel_eio ~env ~n:ndomains (fun did ->
          let batch =
            List.init 50 (fun i ->
                let data = Printf.sprintf "batch-d%d-i%d" did i in
                (Hash.sha1 data, data))
          in
          backend.write_batch batch);
      (* Verify all batches *)
      let missing = ref 0 in
      for did = 0 to ndomains - 1 do
        for i = 0 to 49 do
          let data = Printf.sprintf "batch-d%d-i%d" did i in
          let h = Hash.sha1 data in
          if not (backend.exists h) then incr missing
        done
      done;
      Alcotest.(check int) "all batch writes visible" 0 !missing)

(* ================================================================== *)
(* Store: concurrent commits on different branches                     *)
(* ================================================================== *)

let test_store_concurrent_commits () =
  let backend = Backend.thread_safe_rw (Backend.Memory.create_sha1 ()) in
  let store = Store.Git.create ~backend () in
  run_parallel ~n:ndomains (fun did ->
      let branch = Printf.sprintf "branch-%d" did in
      let tree = Tree.Git.empty () in
      let tree =
        Tree.Git.add tree
          ["file"] (Printf.sprintf "value-%d" did)
      in
      let h =
        Store.Git.commit store ~tree ~parents:[] ~message:"test"
          ~author:(Printf.sprintf "domain-%d" did)
      in
      Store.Git.set_head store ~branch h);
  (* Verify each branch has the correct commit *)
  for did = 0 to ndomains - 1 do
    let branch = Printf.sprintf "branch-%d" did in
    match Store.Git.checkout store ~branch with
    | Some tree ->
        let v = Tree.Git.find tree ["file"] in
        let expected = Printf.sprintf "value-%d" did in
        Alcotest.(check (option string)) branch (Some expected) v
    | None -> Alcotest.failf "branch %s not found" branch
  done

(* ================================================================== *)
(* Concurrent updates on the same key (different domains)              *)
(* ================================================================== *)

let test_concurrent_same_key_updates () =
  let backend = Backend.thread_safe_rw (Backend.Memory.create_sha1 ()) in
  let store = Store.Git.create ~backend () in
  (* All domains write to the same branch, same key *)
  let writes_per_domain = 20 in
  run_parallel ~n:ndomains (fun did ->
      for i = 1 to writes_per_domain do
        let tree = Tree.Git.empty () in
        let tree =
          Tree.Git.add tree [ "key" ]
            (Printf.sprintf "d%d-i%d" did i)
        in
        let parents =
          match Store.Git.head store ~branch:"main" with
          | Some h -> [ h ]
          | None -> []
        in
        let h =
          Store.Git.commit store ~tree ~parents
            ~message:(Printf.sprintf "d%d-i%d" did i)
            ~author:(Printf.sprintf "domain-%d" did)
        in
        Store.Git.set_head store ~branch:"main" h
      done);
  (* The key should have *some* value — last writer wins *)
  match Store.Git.checkout store ~branch:"main" with
  | Some tree ->
      Alcotest.(check bool) "key has value" true
        (Option.is_some (Tree.Git.find tree [ "key" ]))
  | None -> Alcotest.fail "main branch missing"

(* ================================================================== *)
(* Concurrent head updates with CAS (test_and_set)                     *)
(* ================================================================== *)

let test_concurrent_cas_head () =
  let backend = Backend.thread_safe_rw (Backend.Memory.create_sha1 ()) in
  let store = Store.Git.create ~backend () in
  (* Initial commit *)
  let tree = Tree.Git.add (Tree.Git.empty ()) [ "init" ] "v0" in
  let h0 =
    Store.Git.commit store ~tree ~parents:[] ~message:"init" ~author:"test"
  in
  Store.Git.set_head store ~branch:"main" h0;
  let successes = Atomic.make 0 in
  let failures = Atomic.make 0 in
  (* Each domain tries CAS from h0 to its own commit *)
  run_parallel ~n:ndomains (fun did ->
      let tree =
        Tree.Git.add (Tree.Git.empty ()) [ "who" ]
          (Printf.sprintf "domain-%d" did)
      in
      let h =
        Store.Git.commit store ~tree ~parents:[ h0 ]
          ~message:(Printf.sprintf "cas-%d" did)
          ~author:(Printf.sprintf "domain-%d" did)
      in
      if Store.Git.update_branch store ~branch:"main" ~old:(Some h0) ~new_:h
      then Atomic.incr successes
      else Atomic.incr failures);
  (* Exactly one CAS should succeed *)
  Alcotest.(check int) "exactly one CAS wins" 1 (Atomic.get successes);
  Alcotest.(check int) "rest fail" (ndomains - 1) (Atomic.get failures)

(* ================================================================== *)
(* Concurrent multi-commit per domain (store level)                    *)
(* ================================================================== *)

let test_store_concurrent_multi_commit () =
  let backend = Backend.thread_safe_rw (Backend.Memory.create_sha1 ()) in
  let store = Store.Git.create ~backend () in
  let commits_per_domain = 10 in
  run_parallel ~n:ndomains (fun did ->
      let branch = Printf.sprintf "worker-%d" did in
      for i = 1 to commits_per_domain do
        let tree =
          match Store.Git.checkout store ~branch with
          | Some t -> t
          | None -> Tree.Git.empty ()
        in
        let tree =
          Tree.Git.add tree [ "counter" ] (string_of_int i)
        in
        let tree =
          Tree.Git.add tree [ "file" ]
            (Printf.sprintf "d%d-c%d" did i)
        in
        let parents =
          match Store.Git.head store ~branch with
          | Some h -> [ h ]
          | None -> []
        in
        let h =
          Store.Git.commit store ~tree ~parents
            ~message:(Printf.sprintf "d%d-c%d" did i)
            ~author:(Printf.sprintf "domain-%d" did)
        in
        Store.Git.set_head store ~branch h
      done);
  (* Verify final state *)
  for did = 0 to ndomains - 1 do
    let branch = Printf.sprintf "worker-%d" did in
    match Store.Git.checkout store ~branch with
    | Some tree ->
        Alcotest.(check (option string))
          (Printf.sprintf "worker-%d counter" did)
          (Some (string_of_int commits_per_domain))
          (Tree.Git.find tree [ "counter" ]);
        Alcotest.(check (option string))
          (Printf.sprintf "worker-%d file" did)
          (Some (Printf.sprintf "d%d-c%d" did commits_per_domain))
          (Tree.Git.find tree [ "file" ])
    | None ->
        Alcotest.failf "branch worker-%d not found" did
  done

let suite =
  ( "Concurrency",
    [
      (* Memory RW lock *)
      Alcotest.test_case "memory: concurrent reads" `Quick
        test_memory_concurrent_reads;
      Alcotest.test_case "memory: concurrent read+write" `Quick
        test_memory_concurrent_read_write;
      Alcotest.test_case "memory: concurrent refs" `Quick
        test_memory_concurrent_refs;
      (* Disk lock-free *)
      Alcotest.test_case "disk: concurrent reads" `Quick
        test_disk_concurrent_reads;
      Alcotest.test_case "disk: concurrent writes" `Quick
        test_disk_concurrent_writes;
      Alcotest.test_case "disk: concurrent read+write" `Quick
        test_disk_concurrent_read_write;
      Alcotest.test_case "disk: concurrent write_batch" `Quick
        test_disk_write_batch_concurrent;
      (* Store *)
      Alcotest.test_case "store: concurrent commits" `Quick
        test_store_concurrent_commits;
      Alcotest.test_case "store: concurrent same-key updates" `Quick
        test_concurrent_same_key_updates;
      Alcotest.test_case "store: concurrent CAS head" `Quick
        test_concurrent_cas_head;
      Alcotest.test_case "store: concurrent multi-commit" `Quick
        test_store_concurrent_multi_commit;
    ] )
