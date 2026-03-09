(** Benchmark Irmin4 with Lavyek backend across all scenarios.

    Each scenario gets a fresh Lavyek store in a separate subdirectory
    to avoid WAL replay issues between runs. *)

let run_all ?(cache = 0) ~sw ~env root (conf : Bench_common.config) =
  let suffix = if cache > 0 then "+cache" else "" in
  let name = "Irmini" ^ suffix ^ " (lavyek)" in
  let n = ref 0 in
  let run_one f =
    incr n;
    let subdir = Eio.Path.(root / Printf.sprintf "scenario_%d" !n) in
    let b = Backend_lavyek.create ~sw subdir in
    let backend =
      if cache > 0 then Irmin.Backend.cached ~capacity:cache b else b
    in
    Fun.protect
      ~finally:(fun () -> backend.Irmin.Backend.close ())
      (fun () -> f ~backend)
  in
  [
    run_one (fun ~backend -> Bench_irmin4.scenario_commits ~name ~backend conf);
    run_one (fun ~backend -> Bench_irmin4.scenario_reads ~name ~backend conf);
    run_one (fun ~backend ->
        Bench_irmin4.scenario_incremental ~name ~backend conf);
    run_one (fun ~backend ->
        Bench_irmin4.scenario_large_values ~name ~backend conf);
    run_one (fun ~backend ->
        Bench_irmin4.scenario_concurrent ~name ~backend ~env conf);
  ]
