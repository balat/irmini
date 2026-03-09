(** Benchmark official Irmin-Lwt with Git backend. *)

module Store = Irmin_git_unix.FS.KV (Irmin.Contents.String)
module B = Bench_irmin_lwt.Bench (Store)

let run_all conf root =
  let config = Irmin_git.config ~bare:true root in
  let repo = Lwt_main.run (Store.Repo.v config) in
  let results = B.run_all ~name:"Irmin-Lwt (git)" conf repo in
  Lwt_main.run (Store.Repo.close repo);
  results
