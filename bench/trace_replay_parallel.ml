(** Parallel trace replay benchmark for Irmini.

    Replays the Tezos trace by partitioning operations across multiple domains
    and fibers. Each worker processes a contiguous chunk of the trace, sharing
    a backend per domain. This demonstrates how multicore parallelism speeds
    up trace indexing. *)

open Irmin

(** Read the entire trace file into an array for shared read-only access. *)
let load_trace ~trace_path ~flatten_paths =
  let _chan, rows = Trace_replay.open_trace trace_path in
  let rows =
    if flatten_paths then Seq.map Trace_replay.flatten_key_in_op rows
    else rows
  in
  Array.of_seq rows

(** Safe context lookup: returns empty tree if context is unknown
    (happens at chunk boundaries where previous ops were processed
    by another worker). *)
let use_ctx_safe contexts scope =
  let id = Trace_replay.unscope scope in
  match Hashtbl.find_opt contexts id with
  | Some tree ->
    (match scope with
     | Trace_replay.Forget _ -> Hashtbl.remove contexts id
     | Trace_replay.Keep _ -> ());
    tree
  | None -> Tree.Git.empty ()

(** Safe hash lookup: returns None if hash is unknown. *)
let use_hash_safe hashes scope =
  let h = Trace_replay.unscope scope in
  match Hashtbl.find_opt hashes h with
  | Some real_h ->
    (match scope with
     | Trace_replay.Forget _ -> Hashtbl.remove hashes h
     | Trace_replay.Keep _ -> ());
    Some real_h
  | None -> None

(** Process a contiguous chunk of the trace [start_idx, end_idx).
    Returns (total_ops, commits). *)
let replay_chunk ~rows ~start_idx ~end_idx
    ?(empty_blobs = false) ?inline_threshold ?inode
    ~(backend : Hash.sha1 Backend.t) ~worker_id () =
  let store = Store.Git.create ~cache:0 ~backend () in
  let contexts : (int64, Tree.Git.t) Hashtbl.t = Hashtbl.create 16 in
  let hashes : (string, Hash.sha1) Hashtbl.t = Hashtbl.create 16 in
  let branch = Printf.sprintf "worker-%d" worker_id in
  (* Start with empty tree for context 0 *)
  Hashtbl.replace contexts 0L (Tree.Git.empty ());
  let commits = ref 0 in
  let ops = ref 0 in
  for i = start_idx to end_idx - 1 do
    incr ops;
    match rows.(i) with
    | Trace_replay.Checkout (hash_scope, ctx_scope) ->
      (match use_hash_safe hashes hash_scope with
       | Some commit_hash ->
         (match Store.Git.read_commit store commit_hash with
          | Some c ->
            let tree = Store.Git.read_tree store (Commit.Git.tree c) in
            Trace_replay.store_ctx contexts ctx_scope tree
          | None ->
            Trace_replay.store_ctx contexts ctx_scope (Tree.Git.empty ()))
       | None ->
         (* Commit from another worker's chunk — start from empty tree *)
         Trace_replay.store_ctx contexts ctx_scope (Tree.Git.empty ()))

    | Trace_replay.Add { key; value; in_ctx_id; out_ctx_id } ->
      let tree = use_ctx_safe contexts in_ctx_id in
      let v = if empty_blobs then "" else value in
      let tree = Tree.Git.add tree key v in
      Trace_replay.store_ctx contexts out_ctx_id tree

    | Trace_replay.Remove (key, in_ctx_id, out_ctx_id) ->
      let tree = use_ctx_safe contexts in_ctx_id in
      let tree = Tree.Git.remove tree key in
      Trace_replay.store_ctx contexts out_ctx_id tree

    | Trace_replay.Copy { key_src; key_dst; in_ctx_id; out_ctx_id } ->
      let tree = use_ctx_safe contexts in_ctx_id in
      (match Tree.Git.find_tree tree key_src with
       | Some sub ->
         Trace_replay.store_ctx contexts out_ctx_id
           (Tree.Git.add_tree tree key_dst sub)
       | None ->
         Trace_replay.store_ctx contexts out_ctx_id tree)

    | Trace_replay.Find (key, _expected, ctx_scope) ->
      let tree = use_ctx_safe contexts ctx_scope in
      ignore (Tree.Git.find tree key)

    | Trace_replay.Mem (key, _expected, ctx_scope) ->
      let tree = use_ctx_safe contexts ctx_scope in
      ignore (Tree.Git.mem tree key)

    | Trace_replay.Mem_tree (key, _expected, ctx_scope) ->
      let tree = use_ctx_safe contexts ctx_scope in
      ignore (Tree.Git.mem_tree tree key)

    | Trace_replay.Commit { hash = hash_scope; date = _; message = msg;
                            parents; in_ctx_id } ->
      incr commits;
      let tree = use_ctx_safe contexts in_ctx_id in
      let parent_hashes =
        List.filter_map (fun hs -> use_hash_safe hashes hs) parents
      in
      let real_hash =
        Store.Git.commit ?inline_threshold ?inode store ~tree
          ~parents:parent_hashes ~message:msg ~author:"trace-replay"
      in
      Store.Git.set_head store ~branch real_hash;
      Hashtbl.replace hashes
        (Trace_replay.unscope hash_scope) real_hash
  done;
  (!ops, !commits)

(** Run parallel trace replay by partitioning the trace across workers.

    All workers share a single backend. The backend must be thread-safe
    for cross-domain access (use [Backend.thread_safe] for Memory, or
    a backend that is already domain-safe like Lavyek).

    @param ndomains Number of OS domains (cores)
    @param fibers_per_domain Number of concurrent fibers per domain
    @param backend Single shared backend for all workers *)
let replay ~trace_path ?(max_commits = 0) ?(flatten_paths = true)
    ?(empty_blobs = false) ?inline_threshold ?inode
    ~ndomains ~fibers_per_domain
    ~backend ~backend_name ~env () =
  Printf.printf "  Loading trace into memory...\n%!";
  let rows = load_trace ~trace_path ~flatten_paths in
  let nrows = Array.length rows in
  let nworkers = ndomains * fibers_per_domain in
  (* Optionally truncate trace at max_commits *)
  let nrows =
    if max_commits <= 0 then nrows
    else begin
      let commits = ref 0 in
      let limit = ref nrows in
      for i = 0 to nrows - 1 do
        match rows.(i) with
        | Trace_replay.Commit _ ->
          incr commits;
          if !commits >= max_commits && !limit = nrows then
            limit := i + 1
        | _ -> ()
      done;
      !limit
    end
  in
  Printf.printf "  Trace: %d operations, %d workers (%d domains × %d fibers)\n%!"
    nrows nworkers ndomains fibers_per_domain;
  let dm = Eio.Stdenv.domain_mgr env in
  (* Partition ops among workers *)
  let chunk_size = nrows / nworkers in
  let remainder = nrows mod nworkers in
  (* domain_results.(did) = (total_ops, total_commits) *)
  let domain_results = Array.make ndomains (0, 0) in
  let barrier = Atomic.make ndomains in
  let (), total_time =
    Bench_common.time (fun () ->
      let domain_tasks =
        List.init ndomains (fun did () ->
          (* Synchronize domain startup *)
          Atomic.decr barrier;
          while Atomic.get barrier > 0 do
            Domain.cpu_relax ()
          done;
          (* Run fibers concurrently within this domain.
             Eio.Fiber.all gives cooperative concurrency: when a fiber
             blocks on I/O (e.g. Lavyek disk writes), another fiber runs. *)
          let fiber_results = Array.make fibers_per_domain (0, 0) in
          Eio.Fiber.all
            (List.init fibers_per_domain (fun fid () ->
              let worker_id = did * fibers_per_domain + fid in
              (* Compute this worker's chunk range *)
              let start_idx =
                worker_id * chunk_size + min worker_id remainder
              in
              let end_idx =
                start_idx + chunk_size + (if worker_id < remainder then 1 else 0)
              in
              let ops, commits =
                replay_chunk ~rows ~start_idx ~end_idx
                  ~empty_blobs ?inline_threshold ?inode
                  ~backend ~worker_id ()
              in
              fiber_results.(fid) <- (ops, commits)));
          let total_ops = Array.fold_left (fun acc (o, _) -> acc + o) 0 fiber_results in
          let total_commits = Array.fold_left (fun acc (_, c) -> acc + c) 0 fiber_results in
          domain_results.(did) <- (total_ops, total_commits))
      in
      Eio.Fiber.all
        (List.map
           (fun task () -> Eio.Domain_manager.run dm task)
           domain_tasks))
  in
  let total_ops =
    Array.fold_left (fun acc (o, _) -> acc + o) 0 domain_results
  in
  let total_commits =
    Array.fold_left (fun acc (_, c) -> acc + c) 0 domain_results
  in
  Printf.printf
    "  Parallel replay: %d domains × %d fibers/domain\n\
    \  Total: %d commits, %d ops in %.3fs\n\
    \  Throughput: %.0f ops/s\n%!"
    ndomains fibers_per_domain
    total_commits total_ops total_time
    (Float.of_int total_ops /. total_time);
  {
    Bench_common.name = backend_name;
    scenario = Printf.sprintf "tezos-parallel-%dd×%df"
      ndomains fibers_per_domain;
    total_ops;
    total_time;
    ops_per_sec = Float.of_int total_ops /. total_time;
    details = [
      ("domains", Float.of_int ndomains);
      ("fibers/domain", Float.of_int fibers_per_domain);
      ("total_commits", Float.of_int total_commits);
    ];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }
