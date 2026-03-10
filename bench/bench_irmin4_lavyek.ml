(** Benchmark Irmin4 with Lavyek backend across all scenarios.

    Each scenario gets a fresh Lavyek store in a separate subdirectory
    to avoid WAL replay issues between runs. *)

let run_all ?inline_threshold ?inode ?(cache = 0) ?name:custom_name ~sw ~env root (conf : Bench_common.config) =
  let name = match custom_name with
    | Some n -> n
    | None ->
      let suffix = if cache > 0 then "+cache" else "" in
      "Irmini" ^ suffix ^ " (lavyek)" in
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
  let large = { conf with value_size = 10_000 } in
  [
    run_one (fun ~backend -> Bench_irmin4.scenario_commits ?inline_threshold ?inode ~name ~backend conf);
    run_one (fun ~backend -> Bench_irmin4.scenario_reads ?inline_threshold ?inode ~name ~backend conf);
    run_one (fun ~backend ->
        Bench_irmin4.scenario_incremental ?inline_threshold ?inode ~name ~backend conf);
    run_one (fun ~backend -> Bench_irmin4.scenario_commits ?inline_threshold ?inode ~name ~backend large);
    run_one (fun ~backend -> Bench_irmin4.scenario_reads ?inline_threshold ?inode ~name ~backend large);
    run_one (fun ~backend ->
        Bench_irmin4.scenario_incremental ?inline_threshold ?inode ~name ~backend large);
    run_one (fun ~backend ->
        Bench_irmin4.scenario_concurrent ~name ~backend ~env conf);
  ]
