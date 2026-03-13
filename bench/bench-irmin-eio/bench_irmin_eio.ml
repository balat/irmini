(** Benchmark official Irmin (Eio branch) with in-memory and irmin-pack backends.

    Provides the same 4 scenarios as the irmini benchmarks for comparison. *)

module Mem_store = Irmin_mem.KV.Make (Irmin.Contents.String)

let info () = Mem_store.Info.v ~author:"bench" ~message:"commit" 0L

(** Generic benchmark runner parameterised by store module *)
module Bench (S : Irmin.Generic_key.KV with type Schema.Contents.t = string) =
struct
  let info () = S.Info.v ~author:"bench" ~message:"commit" 0L

  let scenario_commits ~name (conf : Bench_common.config) repo =
    let store = S.main repo in
    let paths =
      Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
    in
    let commit_times = ref [] in
    let (), total_time =
      Bench_common.time (fun () ->
          for i = 1 to conf.ncommits do
            let tree = S.get_tree store [] in
            let tree =
              let t = ref tree in
              for n = 1 to conf.tree_add do
                t :=
                  S.Tree.add !t paths.(n)
                    (Bench_common.make_value ~size:conf.value_size i)
              done;
              !t
            in
            let (), ct =
              Bench_common.time (fun () ->
                  S.set_tree_exn store ~info [] tree)
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

  let scenario_reads ~name (conf : Bench_common.config) repo =
    let store = S.main repo in
    let paths =
      Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
    in
    (* Populate *)
    let tree =
      let t = ref (S.Tree.empty ()) in
      for n = 1 to conf.tree_add do
        t :=
          S.Tree.add !t paths.(n)
            (Bench_common.make_value ~size:conf.value_size n)
      done;
      !t
    in
    S.set_tree_exn store ~info [] tree;
    (* Read from a fresh tree loaded from store *)
    let tree = S.get_tree store [] in
    let (), read_time =
      Bench_common.time (fun () ->
          for i = 1 to conf.nreads do
            let n = 1 + (i mod conf.tree_add) in
            ignore (S.Tree.find tree paths.(n))
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

  let scenario_incremental ~name (conf : Bench_common.config) repo =
    let store = S.main repo in
    let paths =
      Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
    in
    (* Build initial tree *)
    let tree =
      let t = ref (S.Tree.empty ()) in
      for n = 1 to conf.tree_add do
        t :=
          S.Tree.add !t paths.(n)
            (Bench_common.make_value ~size:conf.value_size 0)
      done;
      !t
    in
    S.set_tree_exn store ~info [] tree;
    (* Incremental: 1 update per commit *)
    let nops = conf.ncommits in
    let (), total_time =
      Bench_common.time (fun () ->
          for i = 1 to nops do
            let tree = S.get_tree store [] in
            let n = 1 + (i mod conf.tree_add) in
            let tree =
              S.Tree.add tree paths.(n)
                (Bench_common.make_value ~size:conf.value_size i)
            in
            S.set_tree_exn store ~info [] tree
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

  (** Run [f ~fiber_id] for each fiber distributed round-robin across OS domains. *)
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

  let scenario_commits_parallel ?(nfibers = 0) ~name ~env
      (conf : Bench_common.config) repo =
    let ndomains = min 12 (Domain.recommended_domain_count ()) in
    let nfibers = if nfibers <= 0 then 100 else nfibers in
    let commits_per_fiber = max 1 (conf.ncommits / nfibers) in
    let total_ops = commits_per_fiber * nfibers * conf.tree_add in
    let paths =
      Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
    in
    let (), total_time =
      Bench_common.time (fun () ->
          let _nf, _nd = run_on_domains ~env ~nfibers (fun ~fiber_id ->
              let branch =
                S.of_branch repo (Printf.sprintf "fiber-%d" fiber_id)
              in
              for i = 1 to commits_per_fiber do
                let tree = S.get_tree branch [] in
                let tree =
                  let t = ref tree in
                  for n = 1 to conf.tree_add do
                    t :=
                      S.Tree.add !t paths.(n)
                        (Bench_common.make_value ~size:conf.value_size
                           ((fiber_id * commits_per_fiber) + i))
                  done;
                  !t
                in
                S.set_tree_exn branch ~info [] tree
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

  let scenario_reads_parallel ?(nfibers = 0) ~name ~env
      (conf : Bench_common.config) repo =
    let store = S.main repo in
    let paths =
      Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
    in
    (* Populate *)
    let tree =
      let t = ref (S.Tree.empty ()) in
      for n = 1 to conf.tree_add do
        t :=
          S.Tree.add !t paths.(n)
            (Bench_common.make_value ~size:conf.value_size n)
      done;
      !t
    in
    S.set_tree_exn store ~info [] tree;
    let tree = S.get_tree store [] in
    let ndomains = min 12 (Domain.recommended_domain_count ()) in
    let nfibers = if nfibers <= 0 then 100 else nfibers in
    let reads_per_fiber = max 1 (conf.nreads / nfibers) in
    let total_ops = reads_per_fiber * nfibers in
    let (), total_time =
      Bench_common.time (fun () ->
          let _nf, _nd = run_on_domains ~env ~nfibers (fun ~fiber_id ->
              for i = 0 to reads_per_fiber - 1 do
                let n = 1 + ((fiber_id * reads_per_fiber + i) mod conf.tree_add) in
                ignore (S.Tree.find tree paths.(n))
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

  let scenario_incremental_parallel ?(nfibers = 0) ~name ~env
      (conf : Bench_common.config) repo =
    let store = S.main repo in
    let paths =
      Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
    in
    (* Build initial tree *)
    let tree =
      let t = ref (S.Tree.empty ()) in
      for n = 1 to conf.tree_add do
        t :=
          S.Tree.add !t paths.(n)
            (Bench_common.make_value ~size:conf.value_size 0)
      done;
      !t
    in
    S.set_tree_exn store ~info [] tree;
    let ndomains = min 12 (Domain.recommended_domain_count ()) in
    let nfibers = if nfibers <= 0 then 100 else nfibers in
    let ops_per_fiber = max 1 (conf.ncommits / nfibers) in
    let total_ops = ops_per_fiber * nfibers in
    let (), total_time =
      Bench_common.time (fun () ->
          let _nf, _nd = run_on_domains ~env ~nfibers (fun ~fiber_id ->
              let branch =
                S.of_branch repo (Printf.sprintf "fiber-%d" fiber_id)
              in
              for i = 1 to ops_per_fiber do
                let tree = S.get_tree branch [] in
                let n = 1 + (((fiber_id * ops_per_fiber) + i) mod conf.tree_add) in
                let tree =
                  S.Tree.add tree paths.(n)
                    (Bench_common.make_value ~size:conf.value_size
                       ((fiber_id * ops_per_fiber) + i))
                in
                S.set_tree_exn branch ~info [] tree
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

  let run_all ~name (conf : Bench_common.config) repo =
    let large = { conf with value_size = 10_000 } in
    [
      scenario_commits ~name conf repo;
      scenario_reads ~name conf repo;
      scenario_incremental ~name conf repo;
      scenario_commits ~name large repo;
      scenario_reads ~name large repo;
      scenario_incremental ~name large repo;
    ]

  let run_all_with_parallel ?nfibers ~name ~env (conf : Bench_common.config) repo =
    let large = { conf with value_size = 10_000 } in
    run_all ~name conf repo
    @ [
        scenario_commits_parallel ?nfibers ~name ~env conf repo;
        scenario_reads_parallel ?nfibers ~name ~env conf repo;
        scenario_incremental_parallel ?nfibers ~name ~env conf repo;
        scenario_commits_parallel ?nfibers ~name ~env large repo;
        scenario_reads_parallel ?nfibers ~name ~env large repo;
        scenario_incremental_parallel ?nfibers ~name ~env large repo;
      ]
end

module Bench_mem = Bench (Mem_store)

let run_all_mem conf =
  let config = Irmin_mem.config () in
  let repo = Mem_store.Repo.v config in
  let results = Bench_mem.run_all ~name:"Irmin-Eio (memory)" conf repo in
  Mem_store.Repo.close repo;
  results
