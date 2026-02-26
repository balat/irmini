open Irmin

let rec rm_rf path =
  if Eio.Path.is_directory path then begin
    List.iter
      (fun name -> rm_rf Eio.Path.(path / name))
      (Eio.Path.read_dir path);
    Eio.Path.rmdir path
  end
  else if Eio.Path.is_file path then Eio.Path.unlink path

let with_temp_dir f =
  Eio_main.run @@ fun env ->
  let cwd = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let tmp_name = Printf.sprintf "irmin-test-%d" (Random.int 100000) in
  let tmp_path = Eio.Path.(cwd / tmp_name) in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 tmp_path;
  Fun.protect ~finally:(fun () -> rm_rf tmp_path) (fun () -> f ~sw tmp_path)

let test_memory_backend () =
  let backend = Backend.Memory.create_sha1 () in
  let data = "test content" in
  let hash = Hash.sha1 data in
  backend.write hash data;
  Alcotest.(check (option string)) "read back" (Some data) (backend.read hash)

let test_backend_refs () =
  let backend = Backend.Memory.create_sha1 () in
  let data = "content" in
  let hash = Hash.sha1 data in
  backend.write hash data;
  backend.set_ref "refs/heads/main" hash;
  Alcotest.(check bool)
    "ref exists" true
    (Option.is_some (backend.get_ref "refs/heads/main"));
  match backend.get_ref "refs/heads/main" with
  | Some h -> Alcotest.(check bool) "ref matches" true (Hash.equal hash h)
  | None -> Alcotest.fail "ref not found"

let test_backend_test_and_set () =
  let backend = Backend.Memory.create_sha1 () in
  let h1 = Hash.sha1 "content1" in
  let h2 = Hash.sha1 "content2" in
  backend.write h1 "content1";
  backend.write h2 "content2";
  backend.set_ref "ref" h1;
  let result = backend.test_and_set_ref "ref" ~test:(Some h2) ~set:(Some h2) in
  Alcotest.(check bool) "wrong test fails" false result;
  let result = backend.test_and_set_ref "ref" ~test:(Some h1) ~set:(Some h2) in
  Alcotest.(check bool) "correct test succeeds" true result

let test_disk_backend () =
  with_temp_dir @@ fun ~sw tmp_path ->
  let backend = Backend.Disk.create_sha1 ~sw tmp_path in
  let data = "test content" in
  let hash = Hash.sha1 data in
  backend.write hash data;
  Alcotest.(check (option string)) "read back" (Some data) (backend.read hash);
  backend.close ()

let test_disk_backend_persistence () =
  Eio_main.run @@ fun env ->
  let cwd = Eio.Stdenv.cwd env in
  let tmp_name = Printf.sprintf "irmin-test-%d" (Random.int 100000) in
  let tmp_path = Eio.Path.(cwd / tmp_name) in
  let data = "persistent content" in
  let hash = Hash.sha1 data in
  Eio.Switch.run (fun sw ->
      let backend = Backend.Disk.create_sha1 ~sw tmp_path in
      backend.write hash data;
      backend.set_ref "refs/heads/main" hash;
      backend.flush ();
      backend.close ());
  Eio.Switch.run (fun sw ->
      let backend = Backend.Disk.create_sha1 ~sw tmp_path in
      Alcotest.(check (option string))
        "read after reopen" (Some data) (backend.read hash);
      Alcotest.(check bool)
        "ref persisted" true
        (Option.is_some (backend.get_ref "refs/heads/main"));
      backend.close ());
  rm_rf tmp_path

let test_disk_backend_refs () =
  with_temp_dir @@ fun ~sw tmp_path ->
  let backend = Backend.Disk.create_sha1 ~sw tmp_path in
  let data = "content" in
  let hash = Hash.sha1 data in
  backend.write hash data;
  backend.set_ref "refs/heads/main" hash;
  Alcotest.(check bool)
    "ref exists" true
    (Option.is_some (backend.get_ref "refs/heads/main"));
  (match backend.get_ref "refs/heads/main" with
  | Some h -> Alcotest.(check bool) "ref matches" true (Hash.equal hash h)
  | None -> Alcotest.fail "ref not found");
  backend.close ()

let test_disk_backend_write_batch () =
  with_temp_dir @@ fun ~sw tmp_path ->
  let backend = Backend.Disk.create_sha1 ~sw tmp_path in
  let objects =
    [
      (Hash.sha1 "data1", "data1");
      (Hash.sha1 "data2", "data2");
      (Hash.sha1 "data3", "data3");
    ]
  in
  backend.write_batch objects;
  List.iter
    (fun (hash, data) ->
      Alcotest.(check (option string))
        "batch item" (Some data) (backend.read hash))
    objects;
  backend.close ()

let test_disk_backend_wal_recovery () =
  Eio_main.run @@ fun env ->
  let cwd = Eio.Stdenv.cwd env in
  let tmp_name = Printf.sprintf "irmin-wal-test-%d" (Random.int 100000) in
  let tmp_path = Eio.Path.(cwd / tmp_name) in
  let data = "wal recovery content" in
  let hash = Hash.sha1 data in
  Eio.Switch.run (fun sw ->
      let backend = Backend.Disk.create_sha1 ~sw tmp_path in
      backend.write hash data;
      Alcotest.(check (option string))
        "readable before crash" (Some data) (backend.read hash);
      backend.close ());
  Eio.Switch.run (fun sw ->
      let backend = Backend.Disk.create_sha1 ~sw tmp_path in
      Alcotest.(check (option string))
        "recovered from WAL" (Some data) (backend.read hash);
      Alcotest.(check bool) "exists after recovery" true (backend.exists hash);
      backend.close ());
  rm_rf tmp_path

let suite =
  ( "Backend",
    [
      Alcotest.test_case "memory backend" `Quick test_memory_backend;
      Alcotest.test_case "backend refs" `Quick test_backend_refs;
      Alcotest.test_case "backend test_and_set" `Quick test_backend_test_and_set;
      Alcotest.test_case "disk backend" `Quick test_disk_backend;
      Alcotest.test_case "disk backend persistence" `Quick
        test_disk_backend_persistence;
      Alcotest.test_case "disk backend refs" `Quick test_disk_backend_refs;
      Alcotest.test_case "disk backend write_batch" `Quick
        test_disk_backend_write_batch;
      Alcotest.test_case "disk backend WAL recovery" `Quick
        test_disk_backend_wal_recovery;
    ] )
