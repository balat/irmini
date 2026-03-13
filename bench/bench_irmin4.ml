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

(** {1 Helpers for parallel scenarios} *)

(** Run [f ~fiber_id] for each fiber distributed round-robin across OS domains.
    [nfibers] defaults to 100. *)
let run_on_domains ~env ~nfibers f =
  let ndomains = min 12 (Domain.recommended_domain_count ()) in
  let nfibers = if nfibers <= 0 then 100 else nfibers in
  let fibers_per_domain = Array.make ndomains [] in
  for fid = 0 to nfibers - 1 do
    let did = fid mod ndomains in
    fibers_per_domain.(did) <- fid :: fibers_per_domain.(did)
  done;
  let dm = Eio.Stdenv.domain_mgr env in
  let barrier = Atomic.make ndomains in
  let domain_tasks =
    List.init ndomains (fun did () ->
        let my_fibers = fibers_per_domain.(did) in
        Atomic.decr barrier;
        while Atomic.get barrier > 0 do
          Domain.cpu_relax ()
        done;
        List.iter (fun fiber_id -> f ~fiber_id) my_fibers)
  in
  Eio.Fiber.all
    (List.map (fun task () -> Eio.Domain_manager.run dm task) domain_tasks);
  nfibers, ndomains

(** {1 Parallel scenario: commits}

    Same workload as [scenario_commits] but distributed across domains.
    Each fiber commits to its own branch to avoid CAS conflicts. *)
let scenario_commits_parallel ?(nfibers = 0) ?inline_threshold ?inode ~name
    ~(backend : Hash.sha1 Backend.t) ~env (conf : Bench_common.config) =
  let ndomains = min 12 (Domain.recommended_domain_count ()) in
  let nfibers = if nfibers <= 0 then 100 else nfibers in
  let store = Store.Git.create ~backend () in
  let paths =
    Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
  in
  let commits_per_fiber = max 1 (conf.ncommits / nfibers) in
  let total_ops = commits_per_fiber * nfibers * conf.tree_add in
  let (), total_time =
    Bench_common.time (fun () ->
        let _nf, _nd = run_on_domains ~env ~nfibers (fun ~fiber_id ->
            let branch = Printf.sprintf "fiber-%d" fiber_id in
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
                         ((fiber_id * commits_per_fiber) + i))
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
                  ~message:(Printf.sprintf "commit %d/%d" fiber_id i)
                  ~author:"bench"
              in
              Store.Git.set_head store ~branch h
            done)
        in
        ())
  in
  {
    Bench_common.name;
    scenario =
      Printf.sprintf "commits-%s-%df/%dd"
        (Bench_common.fmt_size conf.value_size) nfibers ndomains;
    total_ops;
    total_time;
    ops_per_sec = Float.of_int total_ops /. total_time;
    details =
      [ ("fibers", Float.of_int nfibers);
        ("domains", Float.of_int ndomains) ];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }

(** {1 Parallel scenario: reads}

    Same workload as [scenario_reads] but distributed across domains.
    All fibers read from the same pre-populated store. *)
let scenario_reads_parallel ?(nfibers = 0) ?inline_threshold ?inode ~name
    ~(backend : Hash.sha1 Backend.t) ~env (conf : Bench_common.config) =
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
  let ndomains = min 12 (Domain.recommended_domain_count ()) in
  let nfibers = if nfibers <= 0 then 100 else nfibers in
  let reads_per_fiber = max 1 (conf.nreads / nfibers) in
  let total_ops = reads_per_fiber * nfibers in
  (* Each domain needs its own tree: Tree internals use Lazy which is
     not domain-safe.  Domain.DLS gives one checkout per domain. *)
  let tree_key =
    Domain.DLS.new_key (fun () ->
        match Store.Git.checkout store ~branch:"main" with
        | Some t -> t
        | None -> assert false)
  in
  let (), total_time =
    Bench_common.time (fun () ->
        let _nf, _nd = run_on_domains ~env ~nfibers (fun ~fiber_id ->
            let tree = Domain.DLS.get tree_key in
            for i = 0 to reads_per_fiber - 1 do
              let n = 1 + ((fiber_id * reads_per_fiber + i) mod conf.tree_add) in
              ignore (Tree.Git.find tree paths.(n))
            done)
        in
        ())
  in
  {
    Bench_common.name;
    scenario =
      Printf.sprintf "reads-%s-%df/%dd"
        (Bench_common.fmt_size conf.value_size) nfibers ndomains;
    total_ops;
    total_time;
    ops_per_sec = Float.of_int total_ops /. total_time;
    details =
      [ ("fibers", Float.of_int nfibers);
        ("domains", Float.of_int ndomains) ];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }

(** {1 Parallel scenario: incremental}

    Same workload as [scenario_incremental] but distributed across domains.
    Each fiber does incremental updates on its own branch. *)
let scenario_incremental_parallel ?(nfibers = 0) ?inline_threshold ?inode ~name
    ~(backend : Hash.sha1 Backend.t) ~env (conf : Bench_common.config) =
  let store = Store.Git.create ~backend () in
  let paths =
    Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
  in
  (* Build initial tree and commit to main *)
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
  Store.Git.set_head store ~branch:"main" h;
  let ndomains = min 12 (Domain.recommended_domain_count ()) in
  let nfibers = if nfibers <= 0 then 100 else nfibers in
  let ops_per_fiber = max 1 (conf.ncommits / nfibers) in
  let total_ops = ops_per_fiber * nfibers in
  (* Copy initial commit to each fiber's branch *)
  List.iter
    (fun fid ->
      Store.Git.set_head store
        ~branch:(Printf.sprintf "fiber-%d" fid) h)
    (List.init nfibers Fun.id);
  let (), total_time =
    Bench_common.time (fun () ->
        let _nf, _nd = run_on_domains ~env ~nfibers (fun ~fiber_id ->
            let branch = Printf.sprintf "fiber-%d" fiber_id in
            for i = 1 to ops_per_fiber do
              let tree =
                match Store.Git.checkout store ~branch with
                | Some t -> t
                | None -> assert false
              in
              let n = 1 + (((fiber_id * ops_per_fiber) + i) mod conf.tree_add) in
              let tree =
                Tree.Git.add tree paths.(n)
                  (Bench_common.make_value ~size:conf.value_size
                     ((fiber_id * ops_per_fiber) + i))
              in
              let parents =
                match Store.Git.head store ~branch with
                | Some h -> [ h ]
                | None -> []
              in
              let h =
                Store.Git.commit ?inline_threshold ?inode store ~tree ~parents
                  ~message:(Printf.sprintf "update %d/%d" fiber_id i)
                  ~author:"bench"
              in
              Store.Git.set_head store ~branch h
            done)
        in
        ())
  in
  {
    Bench_common.name;
    scenario =
      Printf.sprintf "incremental-%s-%df/%dd"
        (Bench_common.fmt_size conf.value_size) nfibers ndomains;
    total_ops;
    total_time;
    ops_per_sec = Float.of_int total_ops /. total_time;
    details =
      [ ("fibers", Float.of_int nfibers);
        ("domains", Float.of_int ndomains) ];
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
let run_scenarios ?nfibers ?inline_threshold ?inode
    ~mk_backend ?mk_backend_ts ?close ?(scenarios = all_scenario_ids) ~name ?env
    (conf : Bench_common.config) =
  let confs = [ conf; { conf with value_size = 10_000 } ] in
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
    | None, _ | _, None -> []
    | Some mk_ts, Some env ->
      let backend = mk_ts () in
      [ with_close backend (fun ~backend ->
          match scenario with
          | Commits -> scenario_commits_parallel ?nfibers ?inline_threshold ?inode ~name ~backend ~env c
          | Reads -> scenario_reads_parallel ?nfibers ?inline_threshold ?inode ~name ~backend ~env c
          | Incremental -> scenario_incremental_parallel ?nfibers ?inline_threshold ?inode ~name ~backend ~env c) ]
  in
  List.concat_map (fun c ->
      List.concat_map (fun s ->
          run_seq s c :: run_par s c)
        scenarios)
    confs

(** {1 Backend runners} *)

let run_all_memory ?inline_threshold ?inode ?(cache = 0) ?nfibers ?scenarios ?name:custom_name ~env (conf : Bench_common.config) =
  let name = match custom_name with
    | Some n -> n
    | None ->
      let suffix = if cache > 0 then "+cache" else "" in
      "Irmini" ^ suffix ^ " (memory)"
  in
  let mk_backend () =
    let b = Backend.Memory.create_sha1 () in
    if cache > 0 then Backend.cached ~capacity:cache b else b
  in
  let mk_backend_ts () = Backend.thread_safe (mk_backend ()) in
  run_scenarios ?nfibers ?inline_threshold ?inode ?scenarios
    ~mk_backend ~mk_backend_ts ~name ~env conf

let run_all_git ?(cache = 0) ?scenarios ~sw ~fs root (conf : Bench_common.config) =
  let suffix = if cache > 0 then "+cache" else "" in
  let name = "Irmini" ^ suffix ^ " (git)" in
  let path = Fpath.v (snd root) in
  let store = Git_interop.init_git ~sw ~fs ~path in
  let mk_backend () =
    let b = Store.Git.backend store in
    if cache > 0 then Backend.cached ~capacity:cache b else b
  in
  (* Git backend: disable inlining and inodes for 100% git compatibility.
     No parallel scenarios (no thread-safe git backend). *)
  let inline_threshold = Some 0 in
  let inode = Some false in
  run_scenarios ?inline_threshold ?inode ?scenarios
    ~mk_backend ~name conf

let run_all_disk ?inline_threshold ?inode ?(cache = 0) ?nfibers ?scenarios ?name:custom_name ~sw ~env root (conf : Bench_common.config) =
  let name = match custom_name with
    | Some n -> n
    | None ->
      let suffix = if cache > 0 then "+cache" else "" in
      "Irmini" ^ suffix ^ " (disk)"
  in
  let mk () =
    let b = Backend.Disk.create_sha1 ~sw root in
    if cache > 0 then Backend.cached ~capacity:cache b else b
  in
  let mk_backend () = mk () in
  let mk_backend_ts () = Backend.thread_safe (mk ()) in
  let close (backend : Hash.sha1 Backend.t) = backend.close () in
  run_scenarios ?nfibers ?inline_threshold ?inode ?scenarios
    ~mk_backend ~mk_backend_ts ~close ~name ~env conf
