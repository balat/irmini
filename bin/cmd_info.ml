(** Info command - show store or file information. *)

let print_car_info file data =
  let header, blocks = Atp.Car.of_string ~cid_format:`Atproto data in
  let block_count = List.length blocks in
  let total_size =
    List.fold_left (fun acc (_, d) -> acc + String.length d) 0 blocks
  in
  Fmt.pr "File:    %s@." file;
  Fmt.pr "Format:  CAR v%d@." header.Atp.Car.version;
  Fmt.pr "Roots:   %d@." (List.length header.roots);
  List.iter (fun cid -> Fmt.pr "  %s@." (Atp.Cid.to_string cid)) header.roots;
  Fmt.pr "Blocks:  %d@." block_count;
  Fmt.pr "Size:    %d bytes@." total_size;
  0

let run_file file =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun _sw ->
  let file_path = Eio.Path.(fs / file) in
  let data = Eio.Path.load file_path in
  if Filename.check_suffix file ".car" then print_car_info file data
  else begin
    Fmt.pr "File:    %s@." file;
    Fmt.pr "Size:    %d bytes@." (String.length data);
    0
  end

let run_store ~repo () =
  let config = Config.load ~repo () in
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  Fmt.pr "Store:   %s@." config.Config.store_path;
  Fmt.pr "Backend: %a@." Config.pp_backend config.backend;
  Fmt.pr "Branch:  %s@." config.default_branch;
  match config.backend with
  | Config.Git ->
      let git_dir = Fpath.(v config.store_path / ".git") in
      let store = Irmin.Git_interop.import_git ~sw ~fs ~git_dir in
      let branches = Irmin.Store.Git.branches store in
      Fmt.pr "Branches: %d@." (List.length branches);
      List.iter (fun b -> Fmt.pr "  %s@." b) branches;
      0
  | Config.Mst | Config.Memory ->
      let irmin_dir = Filename.concat config.store_path ".irmin" in
      if Sys.file_exists irmin_dir then Fmt.pr "Store dir: %s@." irmin_dir
      else Fmt.pr "Store dir: (not initialized)@.";
      0

let run ~repo file =
  match file with Some f -> run_file f | None -> run_store ~repo ()
