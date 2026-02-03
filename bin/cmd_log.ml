(** Log command. *)

let run ~repo ~branch ~output ~limit () =
  let config = Config.load ~repo () in
  let (module B : Common.BACKEND) = Common.backend_of_config config in
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let store = B.open_store ~sw ~fs ~config in
  let entries = B.log store ~branch ~limit in
  match entries with
  | [] ->
      (match output with
      | `Human -> Fmt.pr "No commits on %s@." branch
      | `Json -> Fmt.pr "[]@.");
      0
  | _ ->
      (match output with
      | `Human ->
          List.iter
            (fun (e : Common.log_entry) ->
              Fmt.pr "%a %s@.    %s@.@." Common.styled_yellow
                (String.sub e.hash 0 7) e.author e.message)
            entries
      | `Json ->
          List.iter
            (fun (e : Common.log_entry) ->
              Fmt.pr {|{"hash":%S,"author":%S,"message":%S}@.|} e.hash e.author
                e.message)
            entries);
      0
