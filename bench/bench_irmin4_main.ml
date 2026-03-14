(** Irmini benchmark runner.

    Benchmarks Irmini with memory, disk, and lavyek backends across
    multiple scenarios: commits, reads, incremental updates.
    Optionally runs with LRU cache enabled.

    Usage: bench_irmin4_main [--ncommits N] [--tree-add N] [--depth N]
                             [--nreads N] [--value-size N]
                             [--only-backend memory|disk|lavyek|git]
                             [--only-scenario commits|reads|incremental]
                             [--skip-lavyek] [--skip-disk]
                             [--cache N] [--output-dir DIR] *)

let () =
  let ncommits = ref 100 in
  let tree_add = ref 1000 in
  let depth = ref 10 in
  let nreads = ref 1_000_000 in
  let value_size = ref 20 in
  let skip_memory = ref false in
  let skip_lavyek = ref false in
  let skip_disk = ref false in
  let skip_git = ref false in
  let cache = ref 0 in
  let inline_threshold = ref (-1) in
  let no_inode = ref false in
  let name = ref "" in
  let json_file = ref "" in
  let json_merge = ref false in
  let output_dir = ref "" in
  let trace_file = ref "" in
  let trace_max_commits = ref 0 in
  let trace_empty_blobs = ref false in
  let no_flatten = ref false in
  let parallel_domains = ref 0 in
  let parallel_fibers = ref 100 in
  let fsync_variants = ref false in
  let only_backend = ref "" in
  let only_scenario = ref "" in
  Arg.parse
    [
      ("--ncommits", Arg.Set_int ncommits, "Number of commits (default: 100)");
      ("--tree-add", Arg.Set_int tree_add,
       "Tree entries added per commit (default: 1000)");
      ("--depth", Arg.Set_int depth, "Depth of paths (default: 10)");
      ("--nreads", Arg.Set_int nreads,
       "Number of reads in read phase (default: 1000000)");
      ("--value-size", Arg.Set_int value_size,
       "Size of values in bytes (default: 20)");
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
      ("--json", Arg.Set_string json_file, "Write ALL results to FILE");
      ("--json-merge", Arg.Set json_merge,
       "Merge results into existing JSON file (update matching entries, keep others)");
      ("--output-dir", Arg.Set_string output_dir,
       "Write results to per-backend files in DIR (seq_disk.json, par_disk.json, etc.)");
      ("--trace", Arg.Set_string trace_file,
       "Run trace replay from .repr file");
      ("--trace-commits", Arg.Set_int trace_max_commits,
       "Max commits to replay (default: 0 = all)");
      ("--trace-empty-blobs", Arg.Set trace_empty_blobs,
       "Replace blob values with empty strings during trace replay");
      ("--no-flatten", Arg.Set no_flatten,
       "Disable Tezos path flattening during trace replay");
      ("--parallel-domains", Arg.Set_int parallel_domains,
       "Number of domains for parallel scenarios and trace replay (0 = skip, default: 0)");
      ("--parallel-fibers", Arg.Set_int parallel_fibers,
       "Number of fibers per domain for parallel scenarios and trace replay (default: 100)");
      ("--fsync-variants", Arg.Set fsync_variants,
       "Run fsync variants: disk without fsync, lavyek with fsync");
      ("--only-backend", Arg.Set_string only_backend,
       "Run only this backend: memory|disk|lavyek|git");
      ("--only-scenario", Arg.Set_string only_scenario,
       "Run only this scenario: commits|reads|incremental");
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
  let cache_int = !cache in
  let cache = if cache_int > 0 then Some cache_int else None in
  let inline_threshold =
    if !inline_threshold >= 0 then Some !inline_threshold else None
  in
  let inode = if !no_inode then Some false else None in
  let name = if !name <> "" then Some !name else None in
  (* --only-backend overrides skip flags *)
  if !only_backend <> "" then begin
    let b = !only_backend in
    skip_memory := b <> "memory";
    skip_disk := b <> "disk";
    skip_lavyek := b <> "lavyek";
    skip_git := b <> "git";
    if b <> "memory" && b <> "disk" && b <> "lavyek" && b <> "git" then begin
      Format.eprintf "Unknown backend: %s (must be memory|disk|lavyek|git)@." b;
      exit 1
    end
  end;
  (* --only-scenario filters scenario list *)
  let scenarios =
    match !only_scenario with
    | "" -> None
    | "commits" -> Some Bench_irmin4.[Commits]
    | "reads" -> Some Bench_irmin4.[Reads]
    | "incremental" -> Some Bench_irmin4.[Incremental]
    | s ->
      Format.eprintf "Unknown scenario: %s (must be commits|reads|incremental)@." s;
      exit 1
  in
  let ndomains = !parallel_domains in
  let fibers_per_domain = !parallel_fibers in
  let odir = !output_dir in
  Format.printf
    "Configuration: %d commits, %d adds/commit, depth %d, %d reads, \
     %d-byte values%s%s@.@."
    conf.ncommits conf.tree_add conf.depth conf.nreads conf.value_size
    (match cache with Some n -> Printf.sprintf ", cache=%d" n | None -> "")
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
  (* Helper: write results to --output-dir if set *)
  let write_to filename rs =
    if odir <> "" && rs <> [] then
      Bench_common.write_json_merge (Filename.concat odir filename) rs
  in
  (* Helper: print and accumulate run_results *)
  let run_rr label (rr : Bench_common.run_results) =
    let all = Bench_common.all_results rr in
    Format.printf "--- %s ---@.@." label;
    List.iter (fun r -> Format.printf "%a@.@." Bench_common.pp_result r) all;
    results := all @ !results
  in
  (* Helper: print and accumulate a single trace result *)
  let run_trace_result r =
    Format.printf "%a@.@." Bench_common.pp_result r;
    results := [r] @ !results
  in
  (* 1. Irmini disk *)
  if not !skip_disk && not !fsync_variants then begin
    Eio.Switch.run @@ fun sw ->
    let root = Eio.Path.(cwd / "_build/_bench_disk") in
    rm_rf root;
    let disk_name = match name with Some n -> n | None -> "Irmini (disk)" in
    let rr = Bench_irmin4.run_all_disk ?inline_threshold ?inode ~cache:cache_int ~ndomains ~fibers_per_domain ?scenarios ?name ~sw ~env root conf in
    run_rr disk_name rr;
    write_to "seq_disk.json" rr.sequential;
    write_to "par_disk.json" rr.parallel
  end;
  (* 1b. Irmini disk without fsync *)
  if !fsync_variants && not !skip_disk then begin
    Eio.Switch.run @@ fun sw ->
    let root = Eio.Path.(cwd / "_build/_bench_disk_nofsync") in
    rm_rf root;
    let rr = Bench_irmin4.run_all_disk ?inline_threshold ?inode ~use_fsync:false ~cache:cache_int ~ndomains ~fibers_per_domain ?scenarios ~name:"Irmini (disk, no fsync)" ~sw ~env root conf in
    run_rr "Irmini (disk, no fsync)" rr;
    write_to "seq_disk.json" rr.sequential;
    write_to "par_disk.json" rr.parallel
  end;
  (* 2. Irmini memory *)
  if not !skip_memory && not !fsync_variants then begin
    let mem_name = match name with Some n -> n | None -> "Irmini (memory)" in
    (* Memory backend: use 1 fiber/domain — fibers never yield on pure
       CPU ops (String_map), so extra fibers only add scheduling overhead. *)
    let rr = Bench_irmin4.run_all_memory ?inline_threshold ?inode ~cache:cache_int ~ndomains ~fibers_per_domain:1 ?scenarios ?name ~env conf in
    run_rr mem_name rr;
    write_to "seq_memory.json" rr.sequential;
    write_to "par_memory.json" rr.parallel
  end;
  (* 3. Irmini git *)
  if not !skip_git && not !fsync_variants then begin
    Eio.Switch.run @@ fun sw ->
    let root = Eio.Path.(cwd / "_build/_bench_git") in
    rm_rf root;
    Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 root;
    let rr = Bench_irmin4.run_all_git ~cache:cache_int ?scenarios ~sw ~fs:cwd root conf in
    run_rr "Irmini (git)" rr;
    write_to "seq_git.json" rr.sequential;
    write_to "par_git.json" rr.parallel
  end;
  (* 4. Irmini + Lavyek *)
  if not !skip_lavyek && not !fsync_variants then begin
    Eio.Switch.run @@ fun sw ->
    let root = Eio.Path.(cwd / "_build/_bench_lavyek") in
    rm_rf root;
    let rr = Bench_irmin4_lavyek.run_all ?inline_threshold ?inode ~cache:cache_int ~ndomains ~fibers_per_domain ?scenarios ?name ~sw ~env root conf in
    run_rr "Irmini (lavyek)" rr;
    write_to "seq_lavyek.json" rr.sequential;
    write_to "par_lavyek.json" rr.parallel
  end;
  (* 4b. Irmini + Lavyek without fsync *)
  if !fsync_variants && not !skip_lavyek then begin
    Eio.Switch.run @@ fun sw ->
    let root = Eio.Path.(cwd / "_build/_bench_lavyek_nofsync") in
    rm_rf root;
    let rr = Bench_irmin4_lavyek.run_all ?inline_threshold ?inode ~use_fsync:false ~cache:cache_int ~ndomains ~fibers_per_domain ?scenarios ~name:"Irmini (lavyek, no fsync)" ~sw ~env root conf in
    run_rr "Irmini (lavyek, no fsync)" rr;
    write_to "seq_lavyek.json" rr.sequential;
    write_to "par_lavyek.json" rr.parallel
  end;
  (* 5. Trace replay — runs on each active backend *)
  if !trace_file <> "" then begin
    let run_trace ~backend_name ~backend ~trace_file_name =
      Format.printf "--- Trace Replay (%s) ---@.@." backend_name;
      let r =
        Trace_replay.replay
          ~trace_path:!trace_file
          ~max_commits:!trace_max_commits
          ~flatten_paths:(not !no_flatten)
          ~empty_blobs:!trace_empty_blobs
          ?inline_threshold ?inode
          ~backend ()
      in
      let r = { r with Bench_common.name = backend_name } in
      run_trace_result r;
      write_to trace_file_name [r]
    in
    if not !skip_memory then begin
      let backend = Irmin.Backend.Memory.create_sha1 ?cache () in
      run_trace ~backend_name:"Irmini (memory)" ~backend
        ~trace_file_name:"trace_memory.json"
    end;
    if not !skip_disk then begin
      Eio.Switch.run @@ fun sw ->
      let root = Eio.Path.(cwd / "_build/_bench_disk_trace") in
      rm_rf root;
      let backend = Irmin.Backend.Disk.create_sha1 ?cache ~sw root in
      Fun.protect
        ~finally:(fun () -> backend.Irmin.Backend.close ())
        (fun () -> run_trace ~backend_name:"Irmini (disk)" ~backend
            ~trace_file_name:"trace_disk.json")
    end;
    if not !skip_disk then begin
      Eio.Switch.run @@ fun sw ->
      let root = Eio.Path.(cwd / "_build/_bench_disk_nofsync_trace") in
      rm_rf root;
      let backend = Irmin.Backend.Disk.create_sha1 ?cache ~use_fsync:false ~sw root in
      Fun.protect
        ~finally:(fun () -> backend.Irmin.Backend.close ())
        (fun () -> run_trace ~backend_name:"Irmini (disk, no fsync)" ~backend
            ~trace_file_name:"trace_disk.json")
    end;
    if not !skip_lavyek then begin
      Eio.Switch.run @@ fun sw ->
      let root = Eio.Path.(cwd / "_build/_bench_lavyek_trace") in
      rm_rf root;
      let backend = Irmin_lavyek.create ?cache ~sw root in
      Fun.protect
        ~finally:(fun () -> backend.Irmin.Backend.close ())
        (fun () -> run_trace ~backend_name:"Irmini (lavyek)" ~backend
            ~trace_file_name:"trace_lavyek.json")
    end
  end;
  (* 6. Parallel trace replay — GC before to reclaim memory from steps 1-5 *)
  if !trace_file <> "" && !parallel_domains > 0 then begin
    Gc.full_major ();
    let ndomains = !parallel_domains in
    let fibers_per_domain = !parallel_fibers in
    Format.printf "@.--- Parallel Trace Replay (%d domains × %d fibers) ---@.@."
      ndomains fibers_per_domain;
    let run_par_trace ~backend ~backend_name ~trace_file_name ~env =
      let r =
        Trace_replay_parallel.replay
          ~trace_path:!trace_file
          ~max_commits:!trace_max_commits
          ~flatten_paths:(not !no_flatten)
          ~empty_blobs:!trace_empty_blobs
          ?inline_threshold ?inode
          ~ndomains ~fibers_per_domain
          ~backend ~backend_name ~env ()
      in
      run_trace_result r;
      write_to trace_file_name [r]
    in
    if not !skip_memory then begin
      let backend =
        Irmin.Backend.thread_safe_rw (Irmin.Backend.Memory.create_sha1 ?cache ())
      in
      run_par_trace ~backend ~backend_name:"Irmini-parallel (memory)"
        ~trace_file_name:"trace_par_memory.json" ~env
    end;
    if not !skip_disk then begin
      Eio.Switch.run @@ fun sw ->
      let root = Eio.Path.(cwd / "_build/_bench_disk_parallel") in
      rm_rf root;
      let backend = Irmin.Backend.Disk.create_sha1 ?cache ~sw root in
      Fun.protect
        ~finally:(fun () -> backend.Irmin.Backend.close ())
        (fun () ->
          run_par_trace ~backend ~backend_name:"Irmini-parallel (disk)"
            ~trace_file_name:"trace_par_disk.json" ~env)
    end;
    if not !skip_disk then begin
      Eio.Switch.run @@ fun sw ->
      let root = Eio.Path.(cwd / "_build/_bench_disk_nofsync_parallel") in
      rm_rf root;
      let backend = Irmin.Backend.Disk.create_sha1 ?cache ~use_fsync:false ~sw root in
      Fun.protect
        ~finally:(fun () -> backend.Irmin.Backend.close ())
        (fun () ->
          run_par_trace ~backend ~backend_name:"Irmini-parallel (disk, no fsync)"
            ~trace_file_name:"trace_par_disk.json" ~env)
    end;
    if not !skip_lavyek then begin
      Eio.Switch.run @@ fun sw ->
      let root = Eio.Path.(cwd / "_build/_bench_lavyek_parallel") in
      rm_rf root;
      let backend = Irmin_lavyek.create ?cache ~sw root in
      run_par_trace ~backend ~backend_name:"Irmini-parallel (lavyek)"
        ~trace_file_name:"trace_par_lavyek.json" ~env
    end;
    if not !skip_lavyek then begin
      Eio.Switch.run @@ fun sw ->
      let root = Eio.Path.(cwd / "_build/_bench_lavyek_fsync_parallel") in
      rm_rf root;
      let backend = Irmin_lavyek.create ?cache ~use_fsync:true ~sw root in
      run_par_trace ~backend ~backend_name:"Irmini-parallel (lavyek, fsync)"
        ~trace_file_name:"trace_par_lavyek.json" ~env
    end
  end;
  (* Summary *)
  let all = List.rev !results in
  Bench_common.pp_comparison Format.std_formatter all;
  (* JSON output (legacy: dump everything to one file) *)
  if !json_file <> "" then begin
    if !json_merge then begin
      Bench_common.write_json_merge !json_file all
    end else begin
      let oc = open_out !json_file in
      Bench_common.write_json oc all;
      close_out oc;
      Format.printf "Results written to %s@." !json_file
    end
  end
