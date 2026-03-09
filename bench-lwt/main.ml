(** Irmin-Lwt (official, main branch) benchmark runner.

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
    "bench_irmin_lwt - Official Irmin (Lwt) performance benchmarks";
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
  let results = ref [] in
  let rm_rf dir =
    if Sys.file_exists dir then
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))
  in
  let run name rs =
    Format.printf "--- %s ---@.@." name;
    List.iter (fun r -> Format.printf "%a@.@." Bench_common.pp_result r) rs;
    results := rs @ !results
  in
  (* 1. Irmin-Lwt memory *)
  run "Irmin-Lwt (memory)" (Bench_irmin_mem.run_all conf);
  (* 2. Irmin-pack *)
  if not !skip_pack then begin
    let root = "_build/_bench_pack_lwt" in
    rm_rf root;
    run "Irmin-Lwt (pack)" (Bench_irmin_pack.run_all conf root)
  end;
  (* 3. Irmin-fs *)
  if not !skip_fs then begin
    let root = "_build/_bench_irmin_fs_lwt" in
    rm_rf root;
    run "Irmin-Lwt (fs)" (Bench_irmin_fs.run_all conf root)
  end;
  (* 4. Irmin-git *)
  if not !skip_git then begin
    let root = "_build/_bench_irmin_git_lwt" in
    rm_rf root;
    run "Irmin-Lwt (git)" (Bench_irmin_git.run_all conf root)
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
