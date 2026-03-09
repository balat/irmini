(** Benchmark official Irmin-Lwt with filesystem backend. *)

module Store = Irmin_fs_unix.KV.Make (Irmin.Contents.String)
module B = Bench_irmin_lwt.Bench (Store)

let run_all conf root =
  let config = Irmin_fs.config root in
  let repo = Lwt_main.run (Store.Repo.v config) in
  let results = B.run_all ~name:"Irmin-Lwt (fs)" conf repo in
  Lwt_main.run (Store.Repo.close repo);
  results
