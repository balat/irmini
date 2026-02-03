(** Get command. *)

let run ~repo ~branch ~output path =
  let config = Config.load ~repo () in
  let (module B : Common.BACKEND) = Common.backend_of_config config in
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let store = B.open_store ~sw ~fs ~config in
  match B.checkout store ~branch with
  | None ->
      Common.error "Branch %a not found" Common.styled_cyan branch;
      1
  | Some tree -> (
      match B.tree_find tree (Common.path_of_string path) with
      | None ->
          Common.error "Path %a not found" Common.styled_cyan path;
          1
      | Some content ->
          (match output with
          | `Human -> print_string content
          | `Json -> Fmt.pr {|{"path":%S,"content":%S}@.|} path content);
          0)
