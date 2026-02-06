(** Export command - export store to external formats. *)

let run ~repo ~branch ~output () =
  let config = Config.load ~repo () in
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let is_car =
    String.length output > 4
    && String.sub output (String.length output - 4) 4 = ".car"
  in
  match config.Config.backend with
  | Config.Git when is_car ->
      Common.error "CAR export not yet supported for Git backend";
      1
  | Config.Git -> (
      (* Export as bundle or tar - for now just list what would be exported *)
      let git_dir = Fpath.(v config.store_path / ".git") in
      let store = Irmin.Git_interop.import_git ~sw ~fs ~git_dir in
      match Irmin.Store.Git.checkout store ~branch with
      | None ->
          Common.error "Branch %a not found" Common.styled_cyan branch;
          1
      | Some tree ->
          let rec count_entries path =
            let entries = Irmin.Tree.Git.list tree path in
            List.fold_left
              (fun acc (name, kind) ->
                match kind with
                | `Contents -> acc + 1
                | `Node -> count_entries (path @ [ name ]) + acc)
              0 entries
          in
          let n = count_entries [] in
          Common.error "Export to %s not yet implemented (%d entries)" output n;
          1)
  | Config.Mst | Config.Memory ->
      if is_car then begin
        let irmin_dir = Filename.concat config.store_path ".irmin" in
        let blocks_path = Filename.concat irmin_dir "blocks" in
        if not (Sys.file_exists blocks_path) then begin
          Common.error "No MST store found";
          1
        end
        else begin
          (* TODO: Export CAR from blockstore *)
          Common.error "CAR export not yet implemented";
          1
        end
      end
      else begin
        Common.error "Only .car export supported for MST backend";
        1
      end
