(** Del command. *)

let run ~repo ~branch ~message path =
  let message = match message with Some m -> m | None -> "Delete " ^ path in
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
  | Some tree ->
      let tree = B.tree_remove tree (Common.path_of_string path) in
      let parents =
        match B.head store ~branch with None -> [] | Some h -> [ h ]
      in
      let hash =
        B.commit store ~tree ~parents ~message ~author:"irmin <irmin@local>"
      in
      B.set_head store ~branch hash;
      Common.success "%a" Common.styled_faint (B.hash_short hash);
      0
