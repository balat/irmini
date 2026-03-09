(** Benchmark official Irmin-Lwt with in-memory backend. *)

module Store = Irmin_mem.KV.Make (Irmin.Contents.String)
module B = Bench_irmin_lwt.Bench (Store)

let run_all conf =
  let config = Irmin_mem.config () in
  let repo = Lwt_main.run (Store.Repo.v config) in
  let results = B.run_all ~name:"Irmin-Lwt (memory)" conf repo in
  Lwt_main.run (Store.Repo.close repo);
  results
