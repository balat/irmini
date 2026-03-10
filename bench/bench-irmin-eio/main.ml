(** Irmin-Eio (official) benchmark runner.

    Benchmarks official Irmin with in-memory, irmin-pack, irmin-fs, and
    irmin-git backends, using the same scenarios as the irmini benchmarks
    for comparison.

    Usage: main [--ncommits N] [--tree-add N] [--depth N] [--nreads N]
                [--value-size N] [--skip-pack] [--skip-fs] [--skip-git]
                [--json FILE] *)

let () =
  let ncommits = ref 100 in
  let tree_add = ref 1000 in
  let depth = ref 10 in
  let nreads = ref 10_000 in
  let value_size = ref 100 in
  let skip_pack = ref false in
  let skip_fs = ref false in
  let skip_git = ref false in
  let json_file = ref "" in
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
      ("--skip-fs", Arg.Set skip_fs, "Skip irmin-fs benchmark");
      ("--skip-git", Arg.Set skip_git, "Skip irmin-git benchmark");
      ("--json", Arg.Set_string json_file, "Write JSON results to FILE");
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
  let fs = Eio.Stdenv.cwd env in
  let clock = Eio.Stdenv.clock env in
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
  let run name rs =
    Format.printf "--- %s ---@.@." name;
    List.iter (fun r -> Format.printf "%a@.@." Bench_common.pp_result r) rs;
    results := rs @ !results
  in
  (* 1. Irmin-Eio memory *)
  run "Irmin-Eio (memory)" (Bench_irmin_eio.run_all_mem conf);
  (* 2. Irmin-pack *)
  if not !skip_pack then begin
    Eio.Switch.run @@ fun sw ->
    let root = "_build/_bench_pack" in
    rm_rf Eio.Path.(fs / root);
    run "Irmin-Eio (pack)" (Bench_irmin_pack.run_all ~sw ~fs conf root)
  end;
  (* 3. Irmin-fs *)
  if not !skip_fs then begin
    let root = "_build/_bench_irmin_fs" in
    rm_rf Eio.Path.(fs / root);
    run "Irmin-Eio (fs)" (Bench_irmin_fs.run_all ~clock ~fs conf root)
  end;
  (* 4. Irmin-git *)
  if not !skip_git then begin
    let root = "_build/_bench_irmin_git" in
    rm_rf Eio.Path.(fs / root);
    run "Irmin-Eio (git)" (Bench_irmin_git.run_all ~clock conf root)
  end;
  (* Summary *)
  let all = List.rev !results in
  Bench_common.pp_comparison Format.std_formatter all;
  (* JSON output *)
  if !json_file <> "" then begin
    let oc = open_out !json_file in
    Bench_common.write_json oc all;
    close_out oc;
    Format.printf "Results written to %s@." !json_file
  end
