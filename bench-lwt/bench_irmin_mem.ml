(** Benchmark official Irmin-Lwt with in-memory backend. *)

module Store = Irmin_mem.KV.Make (Irmin.Contents.String)
module B = Bench_irmin_lwt.Bench (Store)

let run_all conf =
  Lwt_main.run
    (let open Lwt.Syntax in
    let config = Irmin_mem.config () in
    let* repo = Store.Repo.v config in
    let* results = B.run_all ~name:"Irmin-Lwt (memory)" conf repo in
    let* () = Store.Repo.close repo in
    Lwt.return results)
