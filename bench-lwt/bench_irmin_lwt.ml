(** Benchmark official Irmin (Lwt/main branch) with various backends.

    Provides the same 4 scenarios as the irmini benchmarks for comparison.
    All store operations use Lwt.  *)

(** Generic benchmark runner parameterised by store module *)
module Bench (S : Irmin.KV with type Schema.Contents.t = string) = struct
  let info () = S.Info.v ~author:"bench" ~message:"commit" 0L

  let scenario_commits ~name (conf : Bench_common.config) repo =
    let store = Lwt_main.run (S.main repo) in
    let paths =
      Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
    in
    let commit_times = ref [] in
    let (), total_time =
      Bench_common.time (fun () ->
          for i = 1 to conf.ncommits do
            Lwt_main.run
              (let open Lwt.Syntax in
              let* tree = S.get_tree store [] in
              let* tree =
                let t = ref tree in
                let rec loop n =
                  if n > conf.tree_add then Lwt.return !t
                  else
                    let* t' =
                      S.Tree.add !t paths.(n)
                        (Bench_common.make_value ~size:conf.value_size i)
                    in
                    t := t';
                    loop (n + 1)
                in
                loop 1
              in
              let (), ct =
                Bench_common.time (fun () ->
                    Lwt_main.run
                      (S.set_tree_exn store ~info [] tree))
              in
              commit_times := ct :: !commit_times;
              Lwt.return_unit)
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

  let scenario_reads ~name (conf : Bench_common.config) repo =
    let store = Lwt_main.run (S.main repo) in
    let paths =
      Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
    in
    (* Populate *)
    Lwt_main.run
      (let open Lwt.Syntax in
      let* tree =
        let t = ref (S.Tree.empty ()) in
        let rec loop n =
          if n > conf.tree_add then Lwt.return !t
          else
            let* t' =
              S.Tree.add !t paths.(n)
                (Bench_common.make_value ~size:conf.value_size n)
            in
            t := t';
            loop (n + 1)
        in
        loop 1
      in
      S.set_tree_exn store ~info [] tree);
    (* Read from a fresh tree loaded from store *)
    let tree = Lwt_main.run (S.get_tree store []) in
    let (), read_time =
      Bench_common.time (fun () ->
          for i = 1 to conf.nreads do
            let n = 1 + (i mod conf.tree_add) in
            ignore (Lwt_main.run (S.Tree.find tree paths.(n)))
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

  let scenario_incremental ~name (conf : Bench_common.config) repo =
    let store = Lwt_main.run (S.main repo) in
    let paths =
      Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
    in
    (* Build initial tree *)
    Lwt_main.run
      (let open Lwt.Syntax in
      let* tree =
        let t = ref (S.Tree.empty ()) in
        let rec loop n =
          if n > conf.tree_add then Lwt.return !t
          else
            let* t' =
              S.Tree.add !t paths.(n)
                (Bench_common.make_value ~size:conf.value_size 0)
            in
            t := t';
            loop (n + 1)
        in
        loop 1
      in
      S.set_tree_exn store ~info [] tree);
    (* Incremental: 1 update per commit *)
    let nops = conf.ncommits in
    let (), total_time =
      Bench_common.time (fun () ->
          for i = 1 to nops do
            Lwt_main.run
              (let open Lwt.Syntax in
              let* tree = S.get_tree store [] in
              let n = 1 + (i mod conf.tree_add) in
              let* tree =
                S.Tree.add tree paths.(n)
                  (Bench_common.make_value ~size:conf.value_size i)
              in
              S.set_tree_exn store ~info [] tree)
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

  let scenario_large_values ~name (conf : Bench_common.config) repo =
    let large_size = 10_000 in
    let store = Lwt_main.run (S.main repo) in
    let npaths = min conf.tree_add 200 in
    let paths =
      Array.init (npaths + 1) (Bench_common.path ~depth:conf.depth)
    in
    let nops = conf.ncommits in
    let (), total_time =
      Bench_common.time (fun () ->
          for i = 1 to nops do
            Lwt_main.run
              (let open Lwt.Syntax in
              let* tree = S.get_tree store [] in
              let* tree =
                let t = ref tree in
                let rec loop n =
                  if n > npaths then Lwt.return !t
                  else
                    let* t' =
                      S.Tree.add !t paths.(n)
                        (Bench_common.make_value ~size:large_size
                           ((i * npaths) + n))
                    in
                    t := t';
                    loop (n + 1)
                in
                loop 1
              in
              S.set_tree_exn store ~info [] tree)
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

  let run_all ~name (conf : Bench_common.config) repo =
    [
      scenario_commits ~name conf repo;
      scenario_reads ~name conf repo;
      scenario_incremental ~name conf repo;
      scenario_large_values ~name conf repo;
    ]
end
