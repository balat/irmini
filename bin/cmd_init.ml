(** Init command. *)

open Irmin

let run ~backend path =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let path' = Fpath.v path in
  match backend with
  | `Git ->
      let _store = Git_interop.init_git ~sw ~fs ~path:path' in
      Common.success "Initialised Git repository at %a" Common.styled_bold path
  | `Mst ->
      (* Create .irmin directory with config *)
      let irmin_dir = Filename.concat path ".irmin" in
      (try Unix.mkdir irmin_dir 0o755 with Unix.Unix_error _ -> ());
      let config_path = Filename.concat irmin_dir "config" in
      let oc = open_out config_path in
      output_string oc "backend = mst\n";
      output_string oc "branch = main\n";
      close_out oc;
      Common.success "Initialised MST store at %a" Common.styled_bold path
