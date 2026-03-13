(** Benchmark official Irmin-git (Eio branch) with filesystem Git backend. *)

module Store = Irmin_git_unix.FS.KV (Irmin.Contents.String)
module B = Bench_irmin_eio.Bench (Store)

let run_all ~clock conf root =
  Lwt_eio.with_event_loop ~clock @@ fun _ ->
  let config = Irmin_git.config ~bare:true root in
  let repo = Store.Repo.v config in
  let results = B.run_all ~name:"Irmin-Eio (git)" conf repo in
  Store.Repo.close repo;
  results

let run_all_with_parallel ?nfibers ~clock ~env conf root =
  Lwt_eio.with_event_loop ~clock @@ fun _ ->
  let config = Irmin_git.config ~bare:true root in
  let repo = Store.Repo.v config in
  let results =
    B.run_all_with_parallel ?nfibers ~name:"Irmin-Eio (git)" ~env conf repo
  in
  Store.Repo.close repo;
  results
