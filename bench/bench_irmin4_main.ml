(** Irmini benchmark runner.

    Benchmarks Irmini with memory, disk, and lavyek backends across
    multiple scenarios: commits, reads, incremental updates.
    Optionally runs with LRU cache enabled.

    Usage: bench_irmin4_main [--ncommits N] [--tree-add N] [--depth N]
                             [--nreads N] [--value-size N]
                             [--skip-lavyek] [--skip-disk]
                             [--cache N] *)

let () =
  let ncommits = ref 100 in
  let tree_add = ref 1000 in
  let depth = ref 10 in
  let nreads = ref 10_000 in
  let value_size = ref 100 in
  let skip_memory = ref false in
  let skip_lavyek = ref false in
  let skip_disk = ref false in
  let skip_git = ref false in
  let cache = ref 0 in
  let inline_threshold = ref (-1) in
  let no_inode = ref false in
  let name = ref "" in
  let json_file = ref "" in
  let trace_file = ref "" in
  let trace_max_commits = ref 0 in
  let trace_empty_blobs = ref false in
  let no_flatten = ref false in
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
      ("--skip-memory", Arg.Set skip_memory, "Skip memory backend benchmark");
      ("--skip-lavyek", Arg.Set skip_lavyek, "Skip Lavyek backend benchmark");
      ("--skip-disk", Arg.Set skip_disk, "Skip disk backend benchmark");
      ("--skip-git", Arg.Set skip_git, "Skip git backend benchmark");
      ("--cache", Arg.Set_int cache,
       "LRU cache capacity (default: 0 = no cache)");
      ("--inline-threshold", Arg.Set_int inline_threshold,
       "Inline threshold in bytes (default: codec default, -1 = use default)");
      ("--no-inode", Arg.Set no_inode, "Disable inode splitting");
      ("--name", Arg.Set_string name, "Override benchmark name");
      ("--json", Arg.Set_string json_file, "Write JSON results to FILE");
      ("--trace", Arg.Set_string trace_file,
       "Run trace replay from .repr file");
      ("--trace-commits", Arg.Set_int trace_max_commits,
       "Max commits to replay (default: 0 = all)");
      ("--trace-empty-blobs", Arg.Set trace_empty_blobs,
       "Replace blob values with empty strings during trace replay");
      ("--no-flatten", Arg.Set no_flatten,
       "Disable Tezos path flattening during trace replay");
    ]
    (fun _ -> ())
    "bench_irmin4 - Irmini performance benchmarks";
  let conf : Bench_common.config =
    {
      ncommits = !ncommits;
      tree_add = !tree_add;
      depth = !depth;
      nreads = !nreads;
      value_size = !value_size;
    }
  in
  let cache = !cache in
  let inline_threshold =
    if !inline_threshold >= 0 then Some !inline_threshold else None
  in
  let inode = if !no_inode then Some false else None in
  let name = if !name <> "" then Some !name else None in
  Format.printf
    "Configuration: %d commits, %d adds/commit, depth %d, %d reads, \
     %d-byte values%s%s@.@."
    conf.ncommits conf.tree_add conf.depth conf.nreads conf.value_size
    (if cache > 0 then Printf.sprintf ", cache=%d" cache else "")
    (match inline_threshold with
     | Some n -> Printf.sprintf ", inline_threshold=%d" n
     | None -> "");
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
  let run name rs =
    Format.printf "--- %s ---@.@." name;
    List.iter (fun r -> Format.printf "%a@.@." Bench_common.pp_result r) rs;
    results := rs @ !results
  in
  (* 1. Irmini disk *)
  if not !skip_disk then begin
    Eio.Switch.run @@ fun sw ->
    let root = Eio.Path.(cwd / "_build/_bench_disk") in
    rm_rf root;
    let disk_name = match name with Some n -> n | None -> "Irmini (disk)" in
    run disk_name (Bench_irmin4.run_all_disk ?inline_threshold ?inode ~cache ?name ~sw ~env root conf)
  end;
  (* 2. Irmini memory *)
  if not !skip_memory then begin
    let mem_name = match name with Some n -> n | None -> "Irmini (memory)" in
    run mem_name (Bench_irmin4.run_all_memory ?inline_threshold ?inode ~cache ?name conf)
  end;
  (* 3. Irmini git *)
  if not !skip_git then begin
    Eio.Switch.run @@ fun sw ->
    let root = Eio.Path.(cwd / "_build/_bench_git") in
    rm_rf root;
    Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 root;
    run "Irmini (git)" (Bench_irmin4.run_all_git ~cache ~sw ~fs:cwd root conf)
  end;
  (* 4. Irmini + Lavyek *)
  if not !skip_lavyek then begin
    Eio.Switch.run @@ fun sw ->
    let root = Eio.Path.(cwd / "_build/_bench_lavyek") in
    rm_rf root;
    run "Irmini (lavyek)"
      (Bench_irmin4_lavyek.run_all ?inline_threshold ?inode ~cache ?name ~sw ~env root conf)
  end;
  (* 5. Trace replay *)
  if !trace_file <> "" then begin
    Format.printf "--- Trace Replay ---@.@.";
    let backend =
      let b = Irmin.Backend.Memory.create_sha1 () in
      if cache > 0 then Irmin.Backend.cached ~capacity:cache b else b
    in
    let r =
      Trace_replay.replay
        ~trace_path:!trace_file
        ~max_commits:!trace_max_commits
        ~flatten_paths:(not !no_flatten)
        ~empty_blobs:!trace_empty_blobs
        ?inline_threshold ?inode
        ~backend ()
    in
    Format.printf "%a@.@." Bench_common.pp_result r;
    results := [r] @ !results
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
