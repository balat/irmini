(** List command. *)

let run ~repo ~branch ~output prefix =
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
      let path =
        match prefix with None -> [] | Some p -> Common.path_of_string p
      in
      let entries = B.tree_list tree path in
      (match output with
      | `Human ->
          List.iter
            (fun (name, kind) ->
              let suffix = match kind with `Node -> "/" | `Contents -> "" in
              Fmt.pr "%s%s@." name suffix)
            entries
      | `Json ->
          let json_entries =
            List.map
              (fun (name, kind) ->
                let k =
                  match kind with `Node -> "dir" | `Contents -> "file"
                in
                Fmt.str {|{"name":%S,"type":%S}|} name k)
              entries
          in
          Fmt.pr "[%s]@." (String.concat "," json_entries));
      0
