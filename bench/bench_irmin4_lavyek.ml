(** Benchmark Irmin4 with Lavyek backend across all scenarios. *)

let run_all ~sw root (conf : Bench_common.config) =
  let name = "Irmin4 (lavyek)" in
  let mk () = Backend_lavyek.create ~sw root in
  let run_one f =
    let backend = mk () in
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
