(** Checkout command. *)

let run ~repo ~create branch =
  let config = Config.load ~repo () in
  let (module B : Common.BACKEND) = Common.backend_of_config config in
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let store = B.open_store ~sw ~fs ~config in
  let existing = B.branches store in
  if create then begin
    if List.mem branch existing then begin
      Common.error "Branch %a already exists" Common.styled_cyan branch;
      1
    end
    else begin
      (* Create new branch pointing at current HEAD or empty *)
      (match B.head store ~branch:"main" with
      | Some h -> B.set_head store ~branch h
      | None -> (
          match existing with
          | first :: _ -> (
              match B.head store ~branch:first with
              | Some h -> B.set_head store ~branch h
              | None -> ())
          | [] -> ()));
      Common.success "Created branch %a" Common.styled_cyan branch;
      0
    end
  end
  else begin
    if not (List.mem branch existing) then begin
      Common.error "Branch %a not found" Common.styled_cyan branch;
      1
    end
    else begin
      Common.success "Switched to branch %a" Common.styled_cyan branch;
      0
    end
  end
