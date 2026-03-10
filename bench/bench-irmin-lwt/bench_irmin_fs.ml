(** Benchmark official Irmin-Lwt with filesystem backend. *)

module Store = Irmin_fs_unix.KV.Make (Irmin.Contents.String)
module B = Bench_irmin_lwt.Bench (Store)

let run_all conf root =
  Lwt_main.run
    (let open Lwt.Syntax in
    let config = Irmin_fs.config root in
    let* repo = Store.Repo.v config in
    let* results = B.run_all ~name:"Irmin-Lwt (fs)" conf repo in
    let* () = Store.Repo.close repo in
    Lwt.return results)
