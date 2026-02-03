(** Tree command. *)

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
  | Some tree ->
      let start_path =
        match path with None -> [] | Some p -> Common.path_of_string p
      in
      let rec walk indent path =
        let entries = B.tree_list tree path in
        List.iter
          (fun (name, kind) ->
            let full_path = path @ [ name ] in
            match kind with
            | `Contents -> (
                match output with
                | `Human -> Fmt.pr "%s%s@." indent name
                | `Json ->
                    Fmt.pr {|{"path":%S,"type":"file"}@.|}
                      (String.concat "/" full_path))
            | `Node ->
                (match output with
                | `Human -> Fmt.pr "%s%a/@." indent Common.styled_blue name
                | `Json ->
                    Fmt.pr {|{"path":%S,"type":"dir"}@.|}
                      (String.concat "/" full_path));
                walk (indent ^ "  ") full_path)
          entries
      in
      walk "" start_path;
      0
