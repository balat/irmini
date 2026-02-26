(** Checkout command. *)

let run ~repo ~create branch =
  let config = Config.load ~repo () in
  let (module B : Common.BACKEND) = Common.backend_of_config config in
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let store = B.open_store ~sw ~fs ~config in
  let existing = B.branches store in
  if not create then begin
    if not (List.mem branch existing) then begin
      Common.error "Branch %a not found" Common.styled_cyan branch;
      1
    end
    else begin
      Common.success "Switched to branch %a" Common.styled_cyan branch;
      0
    end
  end
  else if List.mem branch existing then begin
    Common.error "Branch %a already exists" Common.styled_cyan branch;
    1
  end
  else begin
    let candidates = "main" :: List.filter (( <> ) "main") existing in
    let head = List.find_map (fun b -> B.head store ~branch:b) candidates in
    (match head with Some h -> B.set_head store ~branch h | None -> ());
    Common.success "Created branch %a" Common.styled_cyan branch;
    0
  end
