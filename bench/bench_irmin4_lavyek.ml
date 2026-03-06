(** Benchmark Irmin4 with Lavyek backend across all scenarios.

    Each scenario gets a fresh Lavyek store in a separate subdirectory
    to avoid WAL replay issues between runs. *)

let run_all ~sw root (conf : Bench_common.config) =
  let name = "Irmin4 (lavyek)" in
  let n = ref 0 in
  let run_one f =
    incr n;
    let subdir = Eio.Path.(root / Printf.sprintf "scenario_%d" !n) in
    let backend = Backend_lavyek.create ~sw subdir in
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
  ]
