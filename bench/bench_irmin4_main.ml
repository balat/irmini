(** Irmin4 benchmark runner.

    Benchmarks Irmin4 with memory, disk, and lavyek backends across
    multiple scenarios: commits, reads, incremental updates, large values.

    Usage: bench_irmin4_main [--ncommits N] [--tree-add N] [--depth N]
                             [--nreads N] [--value-size N]
                             [--skip-lavyek] [--skip-disk] *)

let () =
  let ncommits = ref 100 in
  let tree_add = ref 1000 in
  let depth = ref 10 in
  let nreads = ref 10_000 in
  let value_size = ref 100 in
  let skip_lavyek = ref false in
  let skip_disk = ref false in
  Arg.parse
    [
      ("--ncommits", Arg.Set_int ncommits, "Number of commits (default: 100)");
      ("--tree-add", Arg.Set_int tree_add,
       "Tree entries added per commit (default: 1000)");
      ("--depth", Arg.Set_int depth, "Depth of paths (default: 10)");
      ("--nreads", Arg.Set_int nreads,
       "Number of reads in read phase (default: 10000)");
      ("--value-size", Arg.Set_int value_size,
       "Size of values in bytes (default: 100)");
      ("--skip-lavyek", Arg.Set skip_lavyek, "Skip Lavyek backend benchmark");
      ("--skip-disk", Arg.Set skip_disk, "Skip disk backend benchmark");
    ]
    (fun _ -> ())
    "bench_irmin4 - Irmin4 performance benchmarks";
  let conf : Bench_common.config =
    {
      ncommits = !ncommits;
      tree_add = !tree_add;
      depth = !depth;
      nreads = !nreads;
      value_size = !value_size;
    }
  in
  Format.printf
    "Configuration: %d commits, %d adds/commit, depth %d, %d reads, \
     %d-byte values@.@."
    conf.ncommits conf.tree_add conf.depth conf.nreads conf.value_size;
  Eio_main.run @@ fun env ->
  let cwd = Eio.Stdenv.cwd env in
  let results = ref [] in
  let rm_rf path =
    let rec rm path =
      if Eio.Path.is_directory path then begin
        List.iter (fun n -> rm Eio.Path.(path / n)) (Eio.Path.read_dir path);
        Eio.Path.rmdir path
      end
      else if Eio.Path.is_file path then Eio.Path.unlink path
    in
    (try rm path with _ -> ())
  in
  (* 1. Irmin4 memory *)
  Format.printf "--- Irmin4 (memory) ---@.@.";
  let rs = Bench_irmin4.run_all_memory conf in
  List.iter (fun r -> Format.printf "%a@.@." Bench_common.pp_result r) rs;
  results := rs @ !results;
  (* 2. Irmin4 disk *)
  if not !skip_disk then begin
    Format.printf "--- Irmin4 (disk) ---@.@.";
    Eio.Switch.run @@ fun sw ->
    let root = Eio.Path.(cwd / "_build/_bench_disk") in
    rm_rf root;
    let rs = Bench_irmin4.run_all_disk ~sw root conf in
    List.iter (fun r -> Format.printf "%a@.@." Bench_common.pp_result r) rs;
    results := rs @ !results
  end;
  (* 3. Irmin4 + Lavyek *)
  if not !skip_lavyek then begin
    Format.printf "--- Irmin4 (lavyek) ---@.@.";
    Eio.Switch.run @@ fun sw ->
    let root = Eio.Path.(cwd / "_build/_bench_lavyek") in
    rm_rf root;
    let rs = Bench_irmin4_lavyek.run_all ~sw root conf in
    List.iter (fun r -> Format.printf "%a@.@." Bench_common.pp_result r) rs;
    results := rs @ !results
  end;
  (* Summary *)
  Bench_common.pp_comparison Format.std_formatter (List.rev !results)
