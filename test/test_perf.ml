(** Performance regression tests.

    Runs micro-benchmarks and compares ops/s against stored baselines.
    A test fails if performance drops below a configurable threshold.

    Baselines are stored in [test/perf_baselines.json] and can be updated
    by running with [PERF_UPDATE_BASELINE=1]. *)

open Irmin

(* --- Configuration -------------------------------------------------------- *)

(** Maximum allowed regression as a fraction (0.20 = 20 %). *)
let default_threshold = 0.20

let threshold =
  match Sys.getenv_opt "PERF_THRESHOLD" with
  | Some s -> (try float_of_string s with _ -> default_threshold)
  | None -> default_threshold

let update_baseline =
  match Sys.getenv_opt "PERF_UPDATE_BASELINE" with
  | Some "1" -> true
  | _ -> false

let baseline_path =
  match Sys.getenv_opt "PERF_BASELINE_PATH" with
  | Some p -> p
  | None -> "test/perf_baselines.json"

(* --- Minimal JSON baseline persistence ----------------------------------- *)

type baseline_entry = { b_name : string; b_ops_per_sec : float }

let read_baselines () =
  if not (Sys.file_exists baseline_path) then []
  else
    let ic = open_in baseline_path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    let entries = ref [] in
    let i = ref 0 in
    let len = String.length s in
    let skip_ws () =
      while
        !i < len
        && (s.[!i] = ' ' || s.[!i] = '\n' || s.[!i] = '\r' || s.[!i] = '\t'
           || s.[!i] = ',')
      do
        incr i
      done
    in
    let read_string () =
      assert (s.[!i] = '"');
      incr i;
      let buf = Buffer.create 64 in
      while !i < len && s.[!i] <> '"' do
        if s.[!i] = '\\' then (
          incr i;
          Buffer.add_char buf s.[!i])
        else Buffer.add_char buf s.[!i];
        incr i
      done;
      incr i;
      Buffer.contents buf
    in
    let read_number () =
      let start = !i in
      while
        !i < len
        && (s.[!i] >= '0' && s.[!i] <= '9'
           || s.[!i] = '.' || s.[!i] = '-' || s.[!i] = 'e' || s.[!i] = 'E'
           || s.[!i] = '+')
      do
        incr i
      done;
      String.sub s start (!i - start)
    in
    (try
       skip_ws ();
       if !i < len && s.[!i] = '[' then incr i;
       while !i < len do
         skip_ws ();
         if !i >= len || s.[!i] = ']' then raise Exit;
         if s.[!i] <> '{' then raise Exit;
         incr i;
         let name = ref "" in
         let ops = ref 0.0 in
         while !i < len && s.[!i] <> '}' do
           skip_ws ();
           if !i < len && s.[!i] = '"' then begin
             let key = read_string () in
             skip_ws ();
             if !i < len && s.[!i] = ':' then incr i;
             skip_ws ();
             if key = "name" then name := read_string ()
             else if key = "ops_per_sec" then ops := float_of_string (read_number ())
             else ignore (read_number ());
             skip_ws ();
             if !i < len && s.[!i] = ',' then incr i
           end
           else incr i
         done;
         if !i < len then incr i;
         entries := { b_name = !name; b_ops_per_sec = !ops } :: !entries;
         skip_ws ()
       done
     with Exit -> ());
    List.rev !entries

let write_baselines entries =
  let oc = open_out baseline_path in
  Printf.fprintf oc "[\n";
  List.iteri
    (fun i e ->
      if i > 0 then Printf.fprintf oc ",\n";
      Printf.fprintf oc "  {\"name\": \"%s\", \"ops_per_sec\": %.1f}" e.b_name
        e.b_ops_per_sec)
    entries;
  Printf.fprintf oc "\n]\n";
  close_out oc

let find_baseline baselines name =
  List.find_opt (fun e -> e.b_name = name) baselines

(* --- Micro-benchmarks ---------------------------------------------------- *)

let time f =
  let t0 = Unix.gettimeofday () in
  let r = f () in
  let t1 = Unix.gettimeofday () in
  (r, t1 -. t0)

(** Memory backend: sequential commits (100 commits × 200 adds). *)
let bench_memory_commits () =
  let backend = Backend.Memory.create_sha1 () in
  let store = Store.Git.create ~backend () in
  let ncommits = 100 in
  let tree_add = 200 in
  let depth = 5 in
  let paths = Array.init (tree_add + 1) (fun n ->
      let rec aux acc = function
        | i when i = depth -> List.rev (string_of_int n :: acc)
        | i -> aux (string_of_int i :: acc) (i + 1)
      in
      aux [] 0)
  in
  let (), elapsed =
    time (fun () ->
        for i = 1 to ncommits do
          let tree =
            match Store.Git.checkout store ~branch:"main" with
            | Some t -> t
            | None -> Tree.Git.empty ()
          in
          let tree =
            let t = ref tree in
            for n = 1 to tree_add do
              t := Tree.Git.add !t paths.(n) (Printf.sprintf "v-%d-%d" i n)
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
              ~message:(Printf.sprintf "c%d" i) ~author:"perf"
          in
          Store.Git.set_head store ~branch:"main" h
        done)
  in
  let total_ops = ncommits * tree_add in
  ("memory-commits", Float.of_int total_ops /. elapsed)

(** Memory backend: random reads after populating. *)
let bench_memory_reads () =
  let backend = Backend.Memory.create_sha1 () in
  let store = Store.Git.create ~backend () in
  let tree_add = 1000 in
  let nreads = 100_000 in
  let depth = 5 in
  let paths = Array.init (tree_add + 1) (fun n ->
      let rec aux acc = function
        | i when i = depth -> List.rev (string_of_int n :: acc)
        | i -> aux (string_of_int i :: acc) (i + 1)
      in
      aux [] 0)
  in
  let tree =
    let t = ref (Tree.Git.empty ()) in
    for n = 1 to tree_add do
      t := Tree.Git.add !t paths.(n) (Printf.sprintf "value-%d" n)
    done;
    !t
  in
  let h =
    Store.Git.commit store ~tree ~parents:[] ~message:"init" ~author:"perf"
  in
  Store.Git.set_head store ~branch:"main" h;
  let tree =
    match Store.Git.checkout store ~branch:"main" with
    | Some t -> t
    | None -> assert false
  in
  let (), elapsed =
    time (fun () ->
        for i = 1 to nreads do
          let n = 1 + (i mod tree_add) in
          ignore (Tree.Git.find tree paths.(n))
        done)
  in
  ("memory-reads", Float.of_int nreads /. elapsed)

(** Memory backend: incremental single-entry updates. *)
let bench_memory_incremental () =
  let backend = Backend.Memory.create_sha1 () in
  let store = Store.Git.create ~backend () in
  let tree_add = 500 in
  let ncommits = 200 in
  let depth = 5 in
  let paths = Array.init (tree_add + 1) (fun n ->
      let rec aux acc = function
        | i when i = depth -> List.rev (string_of_int n :: acc)
        | i -> aux (string_of_int i :: acc) (i + 1)
      in
      aux [] 0)
  in
  let tree =
    let t = ref (Tree.Git.empty ()) in
    for n = 1 to tree_add do
      t := Tree.Git.add !t paths.(n) (Printf.sprintf "value-%d" n)
    done;
    !t
  in
  let h =
    Store.Git.commit store ~tree ~parents:[] ~message:"init" ~author:"perf"
  in
  Store.Git.set_head store ~branch:"main" h;
  let (), elapsed =
    time (fun () ->
        for i = 1 to ncommits do
          let tree =
            match Store.Git.checkout store ~branch:"main" with
            | Some t -> t
            | None -> assert false
          in
          let n = 1 + (i mod tree_add) in
          let tree = Tree.Git.add tree paths.(n) (Printf.sprintf "upd-%d" i) in
          let parents =
            match Store.Git.head store ~branch:"main" with
            | Some h -> [ h ]
            | None -> []
          in
          let h =
            Store.Git.commit store ~tree ~parents
              ~message:(Printf.sprintf "u%d" i) ~author:"perf"
          in
          Store.Git.set_head store ~branch:"main" h
        done)
  in
  ("memory-incremental", Float.of_int ncommits /. elapsed)

(** Disk backend: sequential commits. *)
let bench_disk_commits () =
  Eio_main.run @@ fun env ->
  let cwd = Eio.Stdenv.cwd env in
  Eio.Switch.run @@ fun sw ->
  let tmp = Eio.Path.(cwd / Printf.sprintf "perf-disk-%d" (Random.int 100000)) in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 tmp;
  let backend = Backend.Disk.create_sha1 ~use_fsync:false ~sw tmp in
  let store = Store.Git.create ~backend () in
  let ncommits = 50 in
  let tree_add = 100 in
  let depth = 5 in
  let paths = Array.init (tree_add + 1) (fun n ->
      let rec aux acc = function
        | i when i = depth -> List.rev (string_of_int n :: acc)
        | i -> aux (string_of_int i :: acc) (i + 1)
      in
      aux [] 0)
  in
  let (), elapsed =
    time (fun () ->
        for i = 1 to ncommits do
          let tree =
            match Store.Git.checkout store ~branch:"main" with
            | Some t -> t
            | None -> Tree.Git.empty ()
          in
          let tree =
            let t = ref tree in
            for n = 1 to tree_add do
              t := Tree.Git.add !t paths.(n) (Printf.sprintf "v-%d-%d" i n)
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
              ~message:(Printf.sprintf "c%d" i) ~author:"perf"
          in
          Store.Git.set_head store ~branch:"main" h
        done)
  in
  backend.close ();
  let rec rm_rf path =
    if Eio.Path.is_directory path then begin
      List.iter (fun name -> rm_rf Eio.Path.(path / name)) (Eio.Path.read_dir path);
      Eio.Path.rmdir path
    end
    else if Eio.Path.is_file path then Eio.Path.unlink path
  in
  rm_rf tmp;
  let total_ops = ncommits * tree_add in
  ("disk-commits", Float.of_int total_ops /. elapsed)

(** LRU cache: measure hit throughput. *)
let bench_lru_throughput () =
  let cache = Lru.create 10_000 in
  let nops = 500_000 in
  (* Fill cache *)
  for i = 0 to 9_999 do
    Lru.add cache (string_of_int i) (Printf.sprintf "value-%d" i)
  done;
  let (), elapsed =
    time (fun () ->
        for i = 1 to nops do
          let key = string_of_int (i mod 10_000) in
          ignore (Lru.find cache key)
        done)
  in
  ("lru-throughput", Float.of_int nops /. elapsed)

(* --- Test harness -------------------------------------------------------- *)

let all_benchmarks =
  [
    bench_memory_commits;
    bench_memory_reads;
    bench_memory_incremental;
    bench_disk_commits;
    bench_lru_throughput;
  ]

let test_perf () =
  let baselines = read_baselines () in
  let new_entries = ref [] in
  let failures = ref [] in
  List.iter
    (fun bench ->
      let name, ops_per_sec = bench () in
      new_entries := { b_name = name; b_ops_per_sec = ops_per_sec } :: !new_entries;
      match find_baseline baselines name with
      | None ->
          Format.printf "[PERF] %s: %.0f ops/s (no baseline)@." name ops_per_sec
      | Some base ->
          let ratio = ops_per_sec /. base.b_ops_per_sec in
          let regression = 1.0 -. ratio in
          if regression > threshold then begin
            Format.printf
              "[PERF] %s: REGRESSION %.0f ops/s vs baseline %.0f ops/s \
               (%.1f%% slower, threshold %.0f%%)@."
              name ops_per_sec base.b_ops_per_sec (regression *. 100.0)
              (threshold *. 100.0);
            failures :=
              Printf.sprintf "%s regressed %.1f%% (%.0f -> %.0f ops/s)" name
                (regression *. 100.0) base.b_ops_per_sec ops_per_sec
              :: !failures
          end
          else
            Format.printf "[PERF] %s: OK %.0f ops/s (baseline %.0f, ratio %.2fx)@."
              name ops_per_sec base.b_ops_per_sec ratio)
    all_benchmarks;
  (* Update baselines if requested *)
  if update_baseline then begin
    let new_entries = List.rev !new_entries in
    (* Merge: update existing, add new *)
    let merged =
      List.map
        (fun entry ->
          match find_baseline baselines entry.b_name with
          | Some _ -> entry
          | None -> entry)
        new_entries
      @ List.filter
          (fun b ->
            not (List.exists (fun e -> e.b_name = b.b_name) new_entries))
          baselines
    in
    write_baselines merged;
    Format.printf "[PERF] Baselines updated in %s@." baseline_path
  end;
  match !failures with
  | [] -> ()
  | fs ->
      Alcotest.fail
        (Printf.sprintf "Performance regressions:\n  %s" (String.concat "\n  " fs))

let suite = ("Perf", [ Alcotest.test_case "regression check" `Slow test_perf ])
