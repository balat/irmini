(** Benchmark official Irmin-fs (Eio branch) with filesystem backend. *)

module Store = Irmin_fs_unix.KV.Make (Irmin.Contents.String)
module B = Bench_irmin_eio.Bench (Store)

let run_all ~clock ~fs conf root =
  let config = Irmin_fs_unix.config ~root:Eio.Path.(fs / root) ~clock in
  let repo = Store.Repo.v config in
  let results = B.run_all ~name:"Irmin-Eio (fs)" conf repo in
  Store.Repo.close repo;
  results

let run_all_with_parallel ?nfibers ~clock ~fs ~env conf root =
  let config = Irmin_fs_unix.config ~root:Eio.Path.(fs / root) ~clock in
  let repo = Store.Repo.v config in
  let results =
    B.run_all_with_parallel ?nfibers ~name:"Irmin-Eio (fs)" ~env conf repo
  in
  Store.Repo.close repo;
  results
