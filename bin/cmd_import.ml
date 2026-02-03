(** Import command - import data from external formats. *)

let run ~repo ~branch file =
  let config = Config.load ~repo () in
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let file_path = Eio.Path.(fs / file) in
  let data = Eio.Path.load file_path in
  (* Detect format from extension or content *)
  let is_car =
    String.length file > 4
    && String.sub file (String.length file - 4) 4 = ".car"
  in
  if is_car then begin
    (* Import CAR file *)
    let header, blocks = Atp.Car.of_string ~cid_format:`Atproto data in
    let irmin_dir = Filename.concat config.Config.store_path ".irmin" in
    (try Unix.mkdir irmin_dir 0o755 with Unix.Unix_error _ -> ());
    let store_path = Eio.Path.(fs / irmin_dir / "blocks") in
    let blockstore = Atp.Blockstore.filesystem store_path in
    let count = ref 0 in
    List.iter
      (fun (cid, block_data) ->
        blockstore#put cid block_data;
        incr count)
      blocks;
    blockstore#sync;
    Common.success "Imported %d blocks from %a" !count Common.styled_cyan file;
    ignore header;
    ignore branch;
    0
  end
  else begin
    (* Import as plain content at path *)
    let (module B : Common.BACKEND) = Common.backend_of_config config in
    let store = B.open_store ~sw ~fs ~config in
    let tree =
      match B.checkout store ~branch with
      | None -> B.empty_tree store
      | Some t -> t
    in
    let path = Common.path_of_string file in
    let tree = B.tree_add tree path data in
    let parents =
      match B.head store ~branch with None -> [] | Some h -> [ h ]
    in
    let message = "Import " ^ file in
    let hash =
      B.commit store ~tree ~parents ~message ~author:"irmin <irmin@local>"
    in
    B.set_head store ~branch hash;
    Common.success "Imported %a" Common.styled_cyan file;
    0
  end
