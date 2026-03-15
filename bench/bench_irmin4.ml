(** Benchmark Irmin4 with various backends and scenarios. *)

open Irmin

(** {1 Scenario: Sequential commits with tree adds}

    Each commit adds [tree_add] entries to the tree at [depth]-level paths.
    Measures write throughput and commit overhead. *)
let scenario_commits ?inline_threshold ?inode ~name ~(backend : Hash.sha1 Backend.t)
    (conf : Bench_common.config) =
  let store = Store.Git.create ~backend () in
  let paths =
    Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
  in
  let commit_times = ref [] in
  let (), total_time =
    Bench_common.time (fun () ->
        for i = 1 to conf.ncommits do
          let tree =
            match Store.Git.checkout store ~branch:"main" with
            | Some t -> t
            | None -> Tree.Git.empty ()
          in
          let tree =
            let t = ref tree in
            for n = 1 to conf.tree_add do
              t :=
                Tree.Git.add !t paths.(n)
                  (Bench_common.make_value ~size:conf.value_size i)
            done;
            !t
          in
          let parents =
            match Store.Git.head store ~branch:"main" with
            | Some h -> [ h ]
            | None -> []
          in
          let (), ct =
            Bench_common.time (fun () ->
                let h =
                  Store.Git.commit ?inline_threshold ?inode store ~tree ~parents
                    ~message:(Printf.sprintf "commit %d" i)
                    ~author:"bench"
                in
                Store.Git.set_head store ~branch:"main" h)
          in
          commit_times := ct :: !commit_times
        done)
  in
  let total_ops = conf.ncommits * conf.tree_add in
  let avg_commit =
    let sum = List.fold_left ( +. ) 0.0 !commit_times in
    sum /. Float.of_int conf.ncommits
  in
  {
    Bench_common.name;
    scenario = "commits-" ^ Bench_common.fmt_size conf.value_size;
    total_ops;
    total_time;
    ops_per_sec = Float.of_int total_ops /. total_time;
    details =
      [ ("avg commit", avg_commit);
        ("last commit", List.hd !commit_times) ];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }

(** {1 Scenario: Random reads after populating the store}

    Populates a tree, then reads random entries. Measures read throughput. *)
let scenario_reads ?inline_threshold ?inode ~name ~(backend : Hash.sha1 Backend.t)
    (conf : Bench_common.config) =
  let store = Store.Git.create ~backend () in
  let paths =
    Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
  in
  (* Populate *)
  let tree =
    let t = ref (Tree.Git.empty ()) in
    for n = 1 to conf.tree_add do
      t :=
        Tree.Git.add !t paths.(n)
          (Bench_common.make_value ~size:conf.value_size n)
    done;
    !t
  in
  let h =
    Store.Git.commit ?inline_threshold ?inode store ~tree ~parents:[] ~message:"init" ~author:"bench"
  in
  Store.Git.set_head store ~branch:"main" h;
  (* Read phase - get a fresh tree from the store *)
  let tree =
    match Store.Git.checkout store ~branch:"main" with
    | Some t -> t
    | None -> assert false
  in
  let (), read_time =
    Bench_common.time (fun () ->
        for i = 1 to conf.nreads do
          let n = 1 + (i mod conf.tree_add) in
          ignore (Tree.Git.find tree paths.(n))
        done)
  in
  {
    Bench_common.name;
    scenario = "reads-" ^ Bench_common.fmt_size conf.value_size;
    total_ops = conf.nreads;
    total_time = read_time;
    ops_per_sec = Float.of_int conf.nreads /. read_time;
    details = [];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }

(** {1 Scenario: Incremental updates}

    Updates a single entry per commit across many commits.
    Measures overhead of small updates on a large tree. *)
let scenario_incremental ?inline_threshold ?inode ~name ~(backend : Hash.sha1 Backend.t)
    (conf : Bench_common.config) =
  let store = Store.Git.create ~backend () in
  let paths =
    Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
  in
  (* Build initial tree *)
  let tree =
    let t = ref (Tree.Git.empty ()) in
    for n = 1 to conf.tree_add do
      t := Tree.Git.add !t paths.(n) (Bench_common.make_value ~size:conf.value_size 0)
    done;
    !t
  in
  let h =
    Store.Git.commit ?inline_threshold ?inode store ~tree ~parents:[] ~message:"init" ~author:"bench"
  in
  Store.Git.set_head store ~branch:"main" h;
  (* Incremental updates: modify 1 entry per commit *)
  let nops = conf.ncommits in
  let (), total_time =
    Bench_common.time (fun () ->
        for i = 1 to nops do
          let tree =
            match Store.Git.checkout store ~branch:"main" with
            | Some t -> t
            | None -> assert false
          in
          let n = 1 + (i mod conf.tree_add) in
          let tree =
            Tree.Git.add tree paths.(n)
              (Bench_common.make_value ~size:conf.value_size i)
          in
          let parents =
            match Store.Git.head store ~branch:"main" with
            | Some h -> [ h ]
            | None -> []
          in
          let h =
            Store.Git.commit ?inline_threshold ?inode store ~tree ~parents
              ~message:(Printf.sprintf "update %d" i) ~author:"bench"
          in
          Store.Git.set_head store ~branch:"main" h
        done)
  in
  {
    Bench_common.name;
    scenario = "incremental-" ^ Bench_common.fmt_size conf.value_size;
    total_ops = nops;
    total_time;
    ops_per_sec = Float.of_int nops /. total_time;
    details = [];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }

(** {1 Parallel infrastructure}

    [run_parallel ~ndomains ~fibers_per_domain ~env f] distributes
    [ndomains * fibers_per_domain] workers across OS domains. Each domain
    spawns its fibers with [Eio.Fiber.all] for true cooperative concurrency.
    [f ~worker_id] is called in each fiber and returns a per-worker result.
    Returns an array of all results. *)
let run_parallel ~ndomains ~fibers_per_domain ~env f =
  let nworkers = ndomains * fibers_per_domain in
  let results = Array.make nworkers 0.0 in
  let dm = Eio.Stdenv.domain_mgr env in
  let barrier = Atomic.make ndomains in
  let domain_tasks =
    List.init ndomains (fun did () ->
        (* Synchronize domain startup *)
        Atomic.decr barrier;
        while Atomic.get barrier > 0 do Domain.cpu_relax () done;
        Eio.Fiber.all
          (List.init fibers_per_domain (fun fid () ->
               let worker_id = did * fibers_per_domain + fid in
               let r = f ~worker_id in
               results.(worker_id) <- r)))
  in
  Eio.Fiber.all
    (List.map (fun task () -> Eio.Domain_manager.run dm task) domain_tasks);
  (results, nworkers)

(** {1 Scenario: Parallel reads}

    Pre-populates a shared store, then each fiber reads [nreads/nworkers]
    entries concurrently from the shared tree. *)
let scenario_parallel_reads ?inline_threshold ?inode ~ndomains ~fibers_per_domain
    ~name ~(backend : Hash.sha1 Backend.t) ~env (conf : Bench_common.config) =
  let store = Store.Git.create ~backend () in
  let paths =
    Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
  in
  (* Populate *)
  let tree =
    let t = ref (Tree.Git.empty ()) in
    for n = 1 to conf.tree_add do
      t :=
        Tree.Git.add !t paths.(n)
          (Bench_common.make_value ~size:conf.value_size n)
    done;
    !t
  in
  let h =
    Store.Git.commit ?inline_threshold ?inode store ~tree ~parents:[]
      ~message:"init" ~author:"bench"
  in
  Store.Git.set_head store ~branch:"main" h;
  let tree =
    match Store.Git.checkout store ~branch:"main" with
    | Some t -> t
    | None -> assert false
  in
  let nworkers = ndomains * fibers_per_domain in
  let ops_per_fiber = max 1 (conf.nreads / nworkers) in
  let total_ops = ops_per_fiber * nworkers in
  let (), total_time =
    Bench_common.time (fun () ->
        let _results, _nw =
          run_parallel ~ndomains ~fibers_per_domain ~env (fun ~worker_id ->
              for i = 0 to ops_per_fiber - 1 do
                let n = 1 + ((worker_id * ops_per_fiber + i) mod conf.tree_add) in
                ignore (Tree.Git.find tree paths.(n))
              done;
              Float.of_int ops_per_fiber)
        in
        ())
  in
  {
    Bench_common.name;
    scenario = Printf.sprintf "parallel-reads-%s-%dd×%df"
      (Bench_common.fmt_size conf.value_size) ndomains fibers_per_domain;
    total_ops;
    total_time;
    ops_per_sec = Float.of_int total_ops /. total_time;
    details =
      [ ("domains", Float.of_int ndomains);
        ("fibers/domain", Float.of_int fibers_per_domain) ];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }

(** {1 Scenario: Parallel commits}

    Each fiber works on its own branch, doing [ncommits/nworkers] commits.
    Each commit adds [tree_add] entries. *)
let scenario_parallel_commits ?inline_threshold ?inode ~ndomains ~fibers_per_domain
    ~name ~(backend : Hash.sha1 Backend.t) ~env (conf : Bench_common.config) =
  let store = Store.Git.create ~backend () in
  let paths =
    Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
  in
  let nworkers = ndomains * fibers_per_domain in
  let commits_per_fiber = max 1 (conf.ncommits / nworkers) in
  let total_ops = commits_per_fiber * conf.tree_add * nworkers in
  let (), total_time =
    Bench_common.time (fun () ->
        let _results, _nw =
          run_parallel ~ndomains ~fibers_per_domain ~env (fun ~worker_id ->
              let branch = Printf.sprintf "worker-%d" worker_id in
              for i = 1 to commits_per_fiber do
                let tree =
                  match Store.Git.checkout store ~branch with
                  | Some t -> t
                  | None -> Tree.Git.empty ()
                in
                let tree =
                  let t = ref tree in
                  for n = 1 to conf.tree_add do
                    t :=
                      Tree.Git.add !t paths.(n)
                        (Bench_common.make_value ~size:conf.value_size
                           (worker_id * commits_per_fiber + i))
                  done;
                  !t
                in
                let parents =
                  match Store.Git.head store ~branch with
                  | Some h -> [ h ]
                  | None -> []
                in
                let h =
                  Store.Git.commit ?inline_threshold ?inode store ~tree ~parents
                    ~message:(Printf.sprintf "w%d-c%d" worker_id i)
                    ~author:"bench"
                in
                Store.Git.set_head store ~branch h
              done;
              Float.of_int (commits_per_fiber * conf.tree_add))
        in
        ())
  in
  {
    Bench_common.name;
    scenario = Printf.sprintf "parallel-commits-%s-%dd×%df"
      (Bench_common.fmt_size conf.value_size) ndomains fibers_per_domain;
    total_ops;
    total_time;
    ops_per_sec = Float.of_int total_ops /. total_time;
    details =
      [ ("domains", Float.of_int ndomains);
        ("fibers/domain", Float.of_int fibers_per_domain) ];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }

(** {1 Scenario: Parallel incremental updates}

    Pre-populates a shared tree, then each fiber works on its own branch
    doing single-entry updates per commit. *)
let scenario_parallel_incremental ?inline_threshold ?inode ~ndomains ~fibers_per_domain
    ~name ~(backend : Hash.sha1 Backend.t) ~env (conf : Bench_common.config) =
  let store = Store.Git.create ~backend () in
  let paths =
    Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
  in
  (* Build initial tree *)
  let tree =
    let t = ref (Tree.Git.empty ()) in
    for n = 1 to conf.tree_add do
      t := Tree.Git.add !t paths.(n) (Bench_common.make_value ~size:conf.value_size 0)
    done;
    !t
  in
  let h =
    Store.Git.commit ?inline_threshold ?inode store ~tree ~parents:[]
      ~message:"init" ~author:"bench"
  in
  (* Each worker gets its own branch starting from the same initial commit *)
  let nworkers = ndomains * fibers_per_domain in
  let updates_per_fiber = max 1 (conf.ncommits / nworkers) in
  let total_ops = updates_per_fiber * nworkers in
  for w = 0 to nworkers - 1 do
    Store.Git.set_head store ~branch:(Printf.sprintf "worker-%d" w) h
  done;
  let (), total_time =
    Bench_common.time (fun () ->
        let _results, _nw =
          run_parallel ~ndomains ~fibers_per_domain ~env (fun ~worker_id ->
              let branch = Printf.sprintf "worker-%d" worker_id in
              for i = 1 to updates_per_fiber do
                let tree =
                  match Store.Git.checkout store ~branch with
                  | Some t -> t
                  | None -> assert false
                in
                let n = 1 + (i mod conf.tree_add) in
                let tree =
                  Tree.Git.add tree paths.(n)
                    (Bench_common.make_value ~size:conf.value_size
                       (worker_id * updates_per_fiber + i))
                in
                let parents =
                  match Store.Git.head store ~branch with
                  | Some h -> [ h ]
                  | None -> []
                in
                let h =
                  Store.Git.commit ?inline_threshold ?inode store ~tree ~parents
                    ~message:(Printf.sprintf "w%d-u%d" worker_id i)
                    ~author:"bench"
                in
                Store.Git.set_head store ~branch h
              done;
              Float.of_int updates_per_fiber)
        in
        ())
  in
  {
    Bench_common.name;
    scenario = Printf.sprintf "parallel-incremental-%s-%dd×%df"
      (Bench_common.fmt_size conf.value_size) ndomains fibers_per_domain;
    total_ops;
    total_time;
    ops_per_sec = Float.of_int total_ops /. total_time;
    details =
      [ ("domains", Float.of_int ndomains);
        ("fibers/domain", Float.of_int fibers_per_domain) ];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }

(** {1 Scenario matrix and generic runner} *)

type scenario_id = Commits | Reads | Incremental

let all_scenario_ids = [ Commits; Reads; Incremental ]

let scenario_name = function
  | Commits -> "commits"
  | Reads -> "reads"
  | Incremental -> "incremental"

(** Run all scenarios for a backend.

    [mk_backend ()] creates a fresh sequential backend.
    [mk_backend_ts] (optional) creates a fresh thread-safe backend for parallel
    scenarios.  If [None], parallel scenarios are skipped (e.g. git).
    [~env] is required when [mk_backend_ts] is provided (for Eio domain manager).
    [?close] is called after each scenario to clean up the backend (e.g. disk).
    [?scenarios] filters by scenario id (default: all three).
    Each scenario is run on both the base [conf] and a large-value variant. *)
let run_scenarios ?inline_threshold ?inode
    ~mk_backend ?mk_backend_ts ?close
    ?(ndomains = 0) ?(fibers_per_domain = 1)
    ?(scenarios = all_scenario_ids) ~name ?env
    (conf : Bench_common.config) =
  (* Scale down 10K workload to avoid swap: 100 commits × 1000 adds × 10KB
     = 1GB raw data, which balloons to 10+ GB with index/WAL/bloom/GC.
     Use 10× fewer commits and 5× fewer adds for 10K values to stay under 4GB. *)
  let conf_10k = {
    conf with
    value_size = 10_000;
    ncommits = max 10 (conf.ncommits / 10);
    tree_add = max 200 (conf.tree_add / 5);
  } in
  let confs = [ conf; conf_10k ] in
  let with_close backend f =
    match close with
    | None -> f ~backend
    | Some finally ->
      Fun.protect ~finally:(fun () -> finally backend) (fun () -> f ~backend)
  in
  let run_seq scenario c =
    let backend = mk_backend () in
    with_close backend (fun ~backend ->
      match scenario with
      | Commits -> scenario_commits ?inline_threshold ?inode ~name ~backend c
      | Reads -> scenario_reads ?inline_threshold ?inode ~name ~backend c
      | Incremental -> scenario_incremental ?inline_threshold ?inode ~name ~backend c)
  in
  let run_par scenario c =
    match mk_backend_ts, env with
    | Some mk_ts, Some env when ndomains > 0 ->
      let backend = mk_ts () in
      [ with_close backend (fun ~backend ->
          match scenario with
          | Commits ->
            scenario_parallel_commits ?inline_threshold ?inode
              ~ndomains ~fibers_per_domain ~name ~backend ~env c
          | Reads ->
            scenario_parallel_reads ?inline_threshold ?inode
              ~ndomains ~fibers_per_domain ~name ~backend ~env c
          | Incremental ->
            scenario_parallel_incremental ?inline_threshold ?inode
              ~ndomains ~fibers_per_domain ~name ~backend ~env c) ]
    | _ -> []
  in
  let sequential =
    List.concat_map (fun c ->
        List.map (fun s -> run_seq s c) scenarios)
      confs
  in
  let parallel =
    List.concat_map (fun c ->
        List.concat_map (fun s -> run_par s c) scenarios)
      confs
  in
  { Bench_common.sequential; parallel }

(** {1 Backend runners} *)

let run_all_memory ?inline_threshold ?inode ?(cache = 0)
    ?ndomains ?fibers_per_domain ?scenarios ?name:custom_name ~env
    (conf : Bench_common.config) =
  let name = match custom_name with
    | Some n -> n
    | None ->
      let suffix = if cache > 0 then "+cache" else "" in
      "Irmini" ^ suffix ^ " (memory)"
  in
  let cache = if cache > 0 then Some cache else None in
  let mk_backend () = Backend.Memory.create_sha1 ?cache () in
  let mk_backend_ts () = Backend.thread_safe_rw (mk_backend ()) in
  run_scenarios ?inline_threshold ?inode ?ndomains ?fibers_per_domain ?scenarios
    ~mk_backend ~mk_backend_ts ~name ~env conf

let run_all_git ?(cache = 0) ?scenarios ~sw ~fs root
    (conf : Bench_common.config) =
  let suffix = if cache > 0 then "+cache" else "" in
  let name = "Irmini" ^ suffix ^ " (git)" in
  let path = Fpath.v (snd root) in
  let store = Git_interop.init_git ~sw ~fs ~path in
  let mk_backend () = Store.Git.backend store in
  let inline_threshold = Some 0 in
  let inode = Some false in
  run_scenarios ?inline_threshold ?inode ?scenarios
    ~mk_backend ~name conf

let run_all_disk ?inline_threshold ?inode ?(cache = 0) ?use_fsync
    ?ndomains ?fibers_per_domain ?scenarios ?name:custom_name
    ~sw ~env root (conf : Bench_common.config) =
  let name = match custom_name with
    | Some n -> n
    | None ->
      let suffix = if cache > 0 then "+cache" else "" in
      "Irmini" ^ suffix ^ " (disk)"
  in
  let cache = if cache > 0 then Some cache else None in
  (* Each scenario gets a fresh store in a separate subdirectory
     to avoid data accumulation between scenarios. *)
  let n = ref 0 in
  let mk () =
    incr n;
    let subdir = Eio.Path.(root / Printf.sprintf "scenario_%d" !n) in
    Backend.Disk.create_sha1 ?cache ?use_fsync ~sw subdir
  in
  let mk_backend () = mk () in
  let mk_backend_ts () = mk () in
  let close (backend : Hash.sha1 Backend.t) = backend.close () in
  run_scenarios ?inline_threshold ?inode ?ndomains ?fibers_per_domain ?scenarios
    ~mk_backend ~mk_backend_ts ~close ~name ~env conf
