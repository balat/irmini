(** Branches command. *)

let run ~repo ~output () =
  let config = Config.load ~repo () in
  let (module B : Common.BACKEND) = Common.backend_of_config config in
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let store = B.open_store ~sw ~fs ~config in
  let bs = B.branches store in
  (match output with
  | `Human -> List.iter (Fmt.pr "  %s@.") bs
  | `Json -> Fmt.pr "[%a]@." Fmt.(list ~sep:comma (fmt "%S")) bs);
  0
