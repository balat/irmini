(** Benchmark Irmin4 with various backends and scenarios. *)

open Irmin

(** {1 Scenario: Sequential commits with tree adds}

    Each commit adds [tree_add] entries to the tree at [depth]-level paths.
    Measures write throughput and commit overhead. *)
let scenario_commits ~name ~(backend : Hash.sha1 Backend.t)
    (conf : Bench_common.config) =
  let store = Store.Git.create ~backend in
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
                  Store.Git.commit store ~tree ~parents
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
    scenario = "commits";
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
let scenario_reads ~name ~(backend : Hash.sha1 Backend.t)
    (conf : Bench_common.config) =
  let store = Store.Git.create ~backend in
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
    Store.Git.commit store ~tree ~parents:[] ~message:"init" ~author:"bench"
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
    scenario = "reads";
    total_ops = conf.nreads;
    total_time = read_time;
    ops_per_sec = Float.of_int conf.nreads /. read_time;
    details = [];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }

(** {1 Scenario: Incremental updates}

    Updates a single entry per commit across many commits.
    Measures overhead of small updates on a large tree. *)
let scenario_incremental ~name ~(backend : Hash.sha1 Backend.t)
    (conf : Bench_common.config) =
  let store = Store.Git.create ~backend in
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
    Store.Git.commit store ~tree ~parents:[] ~message:"init" ~author:"bench"
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
            Store.Git.commit store ~tree ~parents
              ~message:(Printf.sprintf "update %d" i) ~author:"bench"
          in
          Store.Git.set_head store ~branch:"main" h
        done)
  in
  {
    Bench_common.name;
    scenario = "incremental";
    total_ops = nops;
    total_time;
    ops_per_sec = Float.of_int nops /. total_time;
    details = [];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }

(** {1 Scenario: Large values}

    Writes large blobs (10 KiB) to test value-size sensitivity. *)
let scenario_large_values ~name ~(backend : Hash.sha1 Backend.t)
    (conf : Bench_common.config) =
  let large_size = 10_000 in
  let store = Store.Git.create ~backend in
  let npaths = min conf.tree_add 200 in
  let paths =
    Array.init (npaths + 1) (Bench_common.path ~depth:conf.depth)
  in
  let nops = conf.ncommits in
  let (), total_time =
    Bench_common.time (fun () ->
        for i = 1 to nops do
          let tree =
            match Store.Git.checkout store ~branch:"main" with
            | Some t -> t
            | None -> Tree.Git.empty ()
          in
          let tree =
            let t = ref tree in
            for n = 1 to npaths do
              t :=
                Tree.Git.add !t paths.(n)
                  (Bench_common.make_value ~size:large_size ((i * npaths) + n))
            done;
            !t
          in
          let parents =
            match Store.Git.head store ~branch:"main" with
            | Some h -> [ h ]
            | None -> []
          in
          let h =
            Store.Git.commit store ~tree ~parents
              ~message:(Printf.sprintf "large %d" i) ~author:"bench"
          in
          Store.Git.set_head store ~branch:"main" h
        done)
  in
  let total_ops = nops * npaths in
  {
    Bench_common.name;
    scenario = "large-values";
    total_ops;
    total_time;
    ops_per_sec = Float.of_int total_ops /. total_time;
    details = [];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }

(** {1 Scenario: Concurrent backend reads/writes}

    Spawns [nfibers] fibers that each write and read objects directly
    on the backend. Tests contention and throughput under parallelism.
    Only meaningful for backends that support concurrent access (disk, lavyek). *)
let scenario_concurrent ~name ~(backend : Hash.sha1 Backend.t)
    ~env (conf : Bench_common.config) =
  let nfibers = min 8 (Domain.recommended_domain_count ()) in
  let ops_per_fiber = conf.nreads / nfibers in
  let total_ops = ops_per_fiber * nfibers * 2 (* read + write *) in
  (* Pre-populate with some objects *)
  let keys = Array.init 1000 (fun i ->
    let data = Bench_common.make_value ~size:conf.value_size i in
    let h = Hash.sha1 data in
    backend.write h data;
    h)
  in
  let (), total_time =
    Bench_common.time (fun () ->
        let dm = Eio.Stdenv.domain_mgr env in
        let barrier = Atomic.make nfibers in
        let tasks = List.init nfibers (fun fiber_id () ->
          (* Spin until all fibers are ready *)
          Atomic.decr barrier;
          while Atomic.get barrier > 0 do Domain.cpu_relax () done;
          for i = 0 to ops_per_fiber - 1 do
            (* Write a new object *)
            let data =
              Bench_common.make_value ~size:conf.value_size
                (fiber_id * ops_per_fiber + i + 1000)
            in
            let h = Hash.sha1 data in
            backend.write h data;
            (* Read a random existing object *)
            let k = keys.(i mod Array.length keys) in
            ignore (backend.read k)
          done)
        in
        Eio.Fiber.all (List.map (fun task () ->
          Eio.Domain_manager.run dm task) tasks))
  in
  {
    Bench_common.name;
    scenario = Printf.sprintf "concurrent-%d" nfibers;
    total_ops;
    total_time;
    ops_per_sec = Float.of_int total_ops /. total_time;
    details = [ ("fibers", Float.of_int nfibers) ];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }

(** {1 Backend runners} *)

let run_all_memory conf =
  let name = "Irmin4 (memory)" in
  let mk () = Backend.Memory.create_sha1 () in
  [
    scenario_commits ~name ~backend:(mk ()) conf;
    scenario_reads ~name ~backend:(mk ()) conf;
    scenario_incremental ~name ~backend:(mk ()) conf;
    scenario_large_values ~name ~backend:(mk ()) conf;
  ]

let run_all_disk ~sw ~env root conf =
  let name = "Irmin4 (disk)" in
  let mk () = Backend.Disk.create_sha1 ~sw root in
  let run_one f =
    let backend = mk () in
    Fun.protect ~finally:(fun () -> backend.close ()) (fun () -> f ~backend)
  in
  [
    run_one (fun ~backend -> scenario_commits ~name ~backend conf);
    run_one (fun ~backend -> scenario_reads ~name ~backend conf);
    run_one (fun ~backend -> scenario_incremental ~name ~backend conf);
    run_one (fun ~backend -> scenario_large_values ~name ~backend conf);
    run_one (fun ~backend -> scenario_concurrent ~name ~backend ~env conf);
  ]
