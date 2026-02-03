(** Set command. *)

let run ~repo ~branch ~message path content =
  let content =
    match content with Some c -> c | None -> In_channel.(input_all stdin)
  in
  let message = match message with Some m -> m | None -> "Set " ^ path in
  let config = Config.load ~repo () in
  let (module B : Common.BACKEND) = Common.backend_of_config config in
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let store = B.open_store ~sw ~fs ~config in
  let tree =
    match B.checkout store ~branch with
    | None -> B.empty_tree store
    | Some t -> t
  in
  let tree = B.tree_add tree (Common.path_of_string path) content in
  let parents =
    match B.head store ~branch with None -> [] | Some h -> [ h ]
  in
  let hash =
    B.commit store ~tree ~parents ~message ~author:"irmin <irmin@local>"
  in
  B.set_head store ~branch hash;
  Common.success "%a" Common.styled_faint (B.hash_short hash)
