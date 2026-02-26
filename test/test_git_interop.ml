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
  let fs = Eio.Stdenv.fs env in
  let cwd = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let tmp_name = Printf.sprintf "irmin-git-test-%d" (Random.int 100000) in
  let tmp_path = Eio.Path.(cwd / tmp_name) in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 tmp_path;
  Fun.protect ~finally:(fun () -> rm_rf tmp_path) (fun () -> f ~sw ~fs tmp_path)

let test_init_git () =
  with_temp_dir @@ fun ~sw ~fs tmp_path ->
  let fpath = Fpath.v (Eio.Path.native_exn tmp_path) in
  let _store = Git_interop.init_git ~sw ~fs ~path:fpath in
  (* Verify .git directory was created *)
  let git_dir = Eio.Path.(tmp_path / ".git") in
  Alcotest.(check bool) "git dir exists" true (Eio.Path.is_directory git_dir)

let test_write_read_object () =
  with_temp_dir @@ fun ~sw ~fs tmp_path ->
  let fpath = Fpath.v (Eio.Path.native_exn tmp_path) in
  let _store = Git_interop.init_git ~sw ~fs ~path:fpath in
  let git_dir = Fpath.(fpath / ".git") in
  let data = "hello world" in
  let hash = Git_interop.write_object ~sw ~fs ~git_dir ~typ:"blob" data in
  match Git_interop.read_object ~sw ~fs ~git_dir hash with
  | Ok (typ, content) ->
      Alcotest.(check string) "type" "blob" typ;
      Alcotest.(check string) "content" data content
  | Error (`Msg msg) -> Alcotest.fail msg

let test_write_read_ref () =
  with_temp_dir @@ fun ~sw ~fs tmp_path ->
  let fpath = Fpath.v (Eio.Path.native_exn tmp_path) in
  let _store = Git_interop.init_git ~sw ~fs ~path:fpath in
  let git_dir = Fpath.(fpath / ".git") in
  let hash = Git_interop.write_object ~sw ~fs ~git_dir ~typ:"blob" "content" in
  Git_interop.write_ref ~sw ~fs ~git_dir "refs/heads/test" hash;
  match Git_interop.read_ref ~sw ~fs ~git_dir "refs/heads/test" with
  | Some h -> Alcotest.(check bool) "ref matches" true (Hash.equal hash h)
  | None -> Alcotest.fail "ref not found"

let suite =
  ( "Git_interop",
    [
      Alcotest.test_case "init git" `Quick test_init_git;
      Alcotest.test_case "write/read object" `Quick test_write_read_object;
      Alcotest.test_case "write/read ref" `Quick test_write_read_ref;
    ] )
