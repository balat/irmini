(** Benchmark official Irmin (Lwt/main branch) with various backends.

    Provides the same 4 scenarios as the irmini benchmarks for comparison.
    All store operations use Lwt. Scenarios return [result Lwt.t] so callers
    can wrap everything in a single [Lwt_main.run]. *)

let time_lwt f =
  let t0 = Unix.gettimeofday () in
  let open Lwt.Syntax in
  let* r = f () in
  let t1 = Unix.gettimeofday () in
  Lwt.return (r, t1 -. t0)

(** Generic benchmark runner parameterised by store module *)
module Bench (S : Irmin.Generic_key.KV with type Schema.Contents.t = string) = struct
  let info () = S.Info.v ~author:"bench" ~message:"commit" 0L

  let scenario_commits ~name (conf : Bench_common.config) repo =
    let open Lwt.Syntax in
    let* store = S.main repo in
    let paths =
      Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
    in
    let commit_times = ref [] in
    let* (), total_time =
      time_lwt (fun () ->
          let rec commit_loop i =
            if i > conf.ncommits then Lwt.return_unit
            else
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
              let t0 = Unix.gettimeofday () in
              let* () = S.set_tree_exn store ~info [] tree in
              let ct = Unix.gettimeofday () -. t0 in
              commit_times := ct :: !commit_times;
              commit_loop (i + 1)
          in
          commit_loop 1)
    in
    let total_ops = conf.ncommits * conf.tree_add in
    let avg_commit =
      let sum = List.fold_left ( +. ) 0.0 !commit_times in
      sum /. Float.of_int conf.ncommits
    in
    Lwt.return
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
    let open Lwt.Syntax in
    let* store = S.main repo in
    let paths =
      Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
    in
    (* Populate *)
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
    let* () = S.set_tree_exn store ~info [] tree in
    (* Read from a fresh tree loaded from store *)
    let* tree = S.get_tree store [] in
    let* (), read_time =
      time_lwt (fun () ->
          let rec read_loop i =
            if i > conf.nreads then Lwt.return_unit
            else
              let n = 1 + (i mod conf.tree_add) in
              let* _ = S.Tree.find tree paths.(n) in
              read_loop (i + 1)
          in
          read_loop 1)
    in
    Lwt.return
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
    let open Lwt.Syntax in
    let* store = S.main repo in
    let paths =
      Array.init (conf.tree_add + 1) (Bench_common.path ~depth:conf.depth)
    in
    (* Build initial tree *)
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
    let* () = S.set_tree_exn store ~info [] tree in
    let nops = conf.ncommits in
    let* (), total_time =
      time_lwt (fun () ->
          let rec inc_loop i =
            if i > nops then Lwt.return_unit
            else
              let* tree = S.get_tree store [] in
              let n = 1 + (i mod conf.tree_add) in
              let* tree =
                S.Tree.add tree paths.(n)
                  (Bench_common.make_value ~size:conf.value_size i)
              in
              let* () = S.set_tree_exn store ~info [] tree in
              inc_loop (i + 1)
          in
          inc_loop 1)
    in
    Lwt.return
      {
        Bench_common.name;
        scenario = "incremental-" ^ Bench_common.fmt_size conf.value_size;
        total_ops = nops;
        total_time;
        ops_per_sec = Float.of_int nops /. total_time;
        details = [];
        maxrss_kb = Bench_common.get_maxrss_kb ();
      }

  let run_all ~name (conf : Bench_common.config) repo =
    let open Lwt.Syntax in
    let large = { conf with value_size = 10_000 } in
    let* r1 = scenario_commits ~name conf repo in
    let* r2 = scenario_reads ~name conf repo in
    let* r3 = scenario_incremental ~name conf repo in
    let* r4 = scenario_commits ~name large repo in
    let* r5 = scenario_reads ~name large repo in
    let* r6 = scenario_incremental ~name large repo in
    Lwt.return [ r1; r2; r3; r4; r5; r6 ]
end
