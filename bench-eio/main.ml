(** Irmin-Eio (official) benchmark runner.

    Benchmarks official Irmin with in-memory and irmin-pack backends,
    using the same scenarios as the irmini benchmarks for comparison.

    Usage: main [--ncommits N] [--tree-add N] [--depth N] [--nreads N]
                [--value-size N] [--skip-pack] *)

let () =
  let ncommits = ref 100 in
  let tree_add = ref 1000 in
  let depth = ref 10 in
  let nreads = ref 10_000 in
  let value_size = ref 100 in
  let skip_pack = ref false in
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
      ("--skip-pack", Arg.Set skip_pack, "Skip irmin-pack benchmark");
    ]
    (fun _ -> ())
    "bench_irmin_eio - Official Irmin (Eio) performance benchmarks";
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
  let results = ref [] in
  (* 1. Irmin-Eio memory *)
  Format.printf "--- Irmin-Eio (memory) ---@.@.";
  let rs = Bench_irmin_eio.run_all_mem conf in
  List.iter (fun r -> Format.printf "%a@.@." Bench_common.pp_result r) rs;
  results := rs @ !results;
  (* 2. Irmin-pack *)
  if not !skip_pack then begin
    Format.printf "--- Irmin-pack (eio) ---@.@.";
    Eio.Switch.run @@ fun sw ->
    let fs = Eio.Stdenv.cwd env in
    let root = Eio.Path.(fs / "_build/_bench_pack") in
    (try
       let rec rm path =
         if Eio.Path.is_directory path then begin
           List.iter (fun n -> rm Eio.Path.(path / n))
             (Eio.Path.read_dir path);
           Eio.Path.rmdir path
         end
         else if Eio.Path.is_file path then Eio.Path.unlink path
       in
       rm root
     with _ -> ());
    let rs = Bench_irmin_pack.run_all ~sw ~fs root conf in
    List.iter (fun r -> Format.printf "%a@.@." Bench_common.pp_result r) rs;
    results := rs @ !results
  end;
  (* Summary *)
  Bench_common.pp_comparison Format.std_formatter (List.rev !results)
