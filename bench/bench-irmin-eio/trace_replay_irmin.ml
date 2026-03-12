(** Trace replay benchmark for Irmin-Eio with parallel support.

    Reads Tezos trace files in .repr format (IrmRepBT) and replays
    the operations using Irmin's Store API. Supports both sequential
    and parallel (multicore + fibers) replay.

    The parallel version partitions the trace across workers (domains ×
    fibers). Tree operations run in parallel; commits are serialized by
    irmin-pack's batch mechanism. *)

(* ------------------------------------------------------------------ *)
(* Trace file types - must match irmin's trace_definitions.ml exactly  *)
(* ------------------------------------------------------------------ *)

type 'a scope = Forget of 'a | Keep of 'a [@@deriving repr]
type key = string list [@@deriving repr]
type hash = string [@@deriving repr]
type message = string [@@deriving repr]
type context_id = int64 [@@deriving repr]

type add = {
  key : key;
  value : string;
  in_ctx_id : context_id scope;
  out_ctx_id : context_id scope;
}
[@@deriving repr]

type copy = {
  key_src : key;
  key_dst : key;
  in_ctx_id : context_id scope;
  out_ctx_id : context_id scope;
}
[@@deriving repr]

type commit_op = {
  hash : hash scope;
  date : int64;
  message : message;
  parents : hash scope list;
  in_ctx_id : context_id scope;
}
[@@deriving repr]

type row =
  | Checkout of hash scope * context_id scope
  | Add of add
  | Remove of key * context_id scope * context_id scope
  | Copy of copy
  | Find of key * bool * context_id scope
  | Mem of key * bool * context_id scope
  | Mem_tree of key * bool * context_id scope
  | Commit of commit_op
[@@deriving repr]

type header = unit [@@deriving repr]

(* ------------------------------------------------------------------ *)
(* Binary file reader                                                  *)
(* ------------------------------------------------------------------ *)

let read_varint chan =
  let max_bits = Sys.word_size - 1 in
  let rec aux n p =
    if p >= max_bits then failwith "Failed to decode varint";
    let i = input_char chan |> Char.code in
    let n = n + ((i land 127) lsl p) in
    if i >= 0 && i < 128 then n else aux n (p + 7)
  in
  aux 0 0

let read_with_prefix decode chan =
  let len = read_varint chan in
  let pos_ref = ref 0 in
  let buf = really_input_string chan len in
  let v = decode buf pos_ref in
  if len <> !pos_ref then
    Printf.ksprintf failwith
      "Trace row expected %d bytes, consumed %d" len !pos_ref;
  v

let open_trace path =
  let chan = open_in_bin path in
  let len = LargeFile.in_channel_length chan in
  if len < 12L then begin
    close_in chan;
    Printf.ksprintf failwith "Trace file '%s' too small (%Ld bytes)" path len
  end;
  let magic = really_input_string chan 8 in
  if magic <> "IrmRepBT" then begin
    close_in chan;
    Printf.ksprintf failwith
      "Bad magic in '%s': expected IrmRepBT, got %s" path
      (String.escaped magic)
  end;
  let decode_i32 = Repr.(decode_bin int32 |> unstage) in
  let version =
    let pos_ref = ref 0 in
    let v = decode_i32 (really_input_string chan 4) pos_ref in
    assert (!pos_ref = 4);
    Int32.to_int v
  in
  if version <> 0 then begin
    close_in chan;
    Printf.ksprintf failwith "Unsupported trace version %d" version
  end;
  let decode_header = Repr.(decode_bin header_t |> unstage) in
  let _header = read_with_prefix decode_header chan in
  let decode_row = Repr.(decode_bin row_t |> unstage) in
  let rec seq () =
    match read_with_prefix decode_row chan with
    | row -> Seq.Cons (row, seq)
    | exception End_of_file -> close_in chan; Seq.Nil
  in
  seq

let load_trace path =
  let rows = open_trace path in
  Array.of_seq rows

(* ------------------------------------------------------------------ *)
(* Scope helpers                                                       *)
(* ------------------------------------------------------------------ *)

let unscope = function Forget x | Keep x -> x

let use_ctx contexts scope =
  let id = unscope scope in
  let ctx = Hashtbl.find contexts id in
  (match scope with Forget _ -> Hashtbl.remove contexts id | Keep _ -> ());
  ctx

let use_ctx_safe contexts scope empty_tree =
  let id = unscope scope in
  match Hashtbl.find_opt contexts id with
  | Some tree ->
    (match scope with Forget _ -> Hashtbl.remove contexts id | Keep _ -> ());
    tree
  | None -> empty_tree

let use_hash hashes scope =
  let h = unscope scope in
  let v = Hashtbl.find hashes h in
  (match scope with Forget _ -> Hashtbl.remove hashes h | Keep _ -> ());
  v

let use_hash_safe hashes scope =
  let h = unscope scope in
  match Hashtbl.find_opt hashes h with
  | Some v ->
    (match scope with Forget _ -> Hashtbl.remove hashes h | Keep _ -> ());
    Some v
  | None -> None

let store_ctx contexts scope tree =
  Hashtbl.replace contexts (unscope scope) tree

(* ------------------------------------------------------------------ *)
(* Truncate trace at max_commits                                       *)
(* ------------------------------------------------------------------ *)

let truncate_rows rows max_commits =
  if max_commits <= 0 then Array.length rows
  else begin
    let nrows = Array.length rows in
    let commits = ref 0 in
    let limit = ref nrows in
    for i = 0 to nrows - 1 do
      match rows.(i) with
      | Commit _ ->
        incr commits;
        if !commits >= max_commits && !limit = nrows then
          limit := i + 1
      | _ -> ()
    done;
    !limit
  end

(* ------------------------------------------------------------------ *)
(* Replay functor                                                      *)
(* ------------------------------------------------------------------ *)

module Make (S : Irmin.Generic_key.KV with type Schema.Contents.t = string) =
struct
  (** Sequential trace replay on irmin store. *)
  let replay ~trace_path ?(max_commits = 0) ?(empty_blobs = false)
      ~repo ~backend_name () =
    Printf.printf "  Loading trace...\n%!";
    let rows = load_trace trace_path in
    let nrows = truncate_rows rows max_commits in
    Printf.printf "  Trace: %d operations\n%!" nrows;
    let store = S.main repo in
    let contexts : (int64, S.tree) Hashtbl.t = Hashtbl.create 16 in
    let hashes : (string, S.commit) Hashtbl.t = Hashtbl.create 16 in
    Hashtbl.replace contexts 0L (S.Tree.empty ());
    let commit_count = ref 0 in
    let total_ops = ref 0 in
    let (), total_time =
      Bench_common.time (fun () ->
        for i = 0 to nrows - 1 do
          incr total_ops;
          match rows.(i) with
          | Checkout (hash_scope, ctx_scope) ->
            (match use_hash_safe hashes hash_scope with
             | Some commit ->
               store_ctx contexts ctx_scope (S.Commit.tree commit)
             | None ->
               store_ctx contexts ctx_scope (S.Tree.empty ()))

          | Add { key; value; in_ctx_id; out_ctx_id } ->
            let tree = use_ctx contexts in_ctx_id in
            let v = if empty_blobs then "" else value in
            store_ctx contexts out_ctx_id (S.Tree.add tree key v)

          | Remove (key, in_ctx_id, out_ctx_id) ->
            let tree = use_ctx contexts in_ctx_id in
            store_ctx contexts out_ctx_id (S.Tree.remove tree key)

          | Copy { key_src; key_dst; in_ctx_id; out_ctx_id } ->
            let tree = use_ctx contexts in_ctx_id in
            (match S.Tree.find_tree tree key_src with
             | Some sub ->
               store_ctx contexts out_ctx_id
                 (S.Tree.add_tree tree key_dst sub)
             | None ->
               store_ctx contexts out_ctx_id tree)

          | Find (key, _, ctx_scope) ->
            let tree = use_ctx contexts ctx_scope in
            ignore (S.Tree.find tree key)

          | Mem (key, _, ctx_scope) ->
            let tree = use_ctx contexts ctx_scope in
            ignore (S.Tree.mem tree key)

          | Mem_tree (key, _, ctx_scope) ->
            let tree = use_ctx contexts ctx_scope in
            ignore (S.Tree.mem_tree tree key)

          | Commit { hash = hash_scope; message = msg; in_ctx_id; _ } ->
            incr commit_count;
            let tree = use_ctx contexts in_ctx_id in
            let info () =
              S.Info.v ~author:"trace-replay" ~message:msg 0L
            in
            S.set_tree_exn store ~info [] tree;
            (match S.Head.find store with
             | Some c ->
               Hashtbl.replace hashes (unscope hash_scope) c
             | None -> ());
            if !commit_count mod 100 = 0 then
              Printf.printf "\r  %d commits replayed%!" !commit_count
        done)
    in
    if !commit_count >= 100 then Printf.printf "\r";
    let total = !total_ops in
    Printf.printf "  Trace replay: %d commits, %d total ops in %.3fs\n%!"
      !commit_count total total_time;
    Printf.printf "  Throughput: %.0f ops/s\n%!"
      (Float.of_int total /. total_time);
    {
      Bench_common.name = backend_name;
      scenario = Printf.sprintf "tezos-%dcommits" !commit_count;
      total_ops = total;
      total_time;
      ops_per_sec = Float.of_int total /. total_time;
      details = [
        ("commits", Float.of_int !commit_count);
      ];
      maxrss_kb = Bench_common.get_maxrss_kb ();
    }

  (** Process a contiguous chunk of the trace.
      Each worker gets its own branch to avoid commit contention.
      Returns (total_ops, total_commits). *)
  let replay_chunk ~rows ~start_idx ~end_idx ?(empty_blobs = false)
      ~repo ~worker_id () =
    let branch = Printf.sprintf "worker-%d" worker_id in
    let store = S.of_branch repo branch in
    let contexts : (int64, S.tree) Hashtbl.t = Hashtbl.create 16 in
    let hashes : (string, S.commit) Hashtbl.t = Hashtbl.create 16 in
    Hashtbl.replace contexts 0L (S.Tree.empty ());
    let commits = ref 0 in
    let ops = ref 0 in
    for i = start_idx to end_idx - 1 do
      incr ops;
      match rows.(i) with
      | Checkout (hash_scope, ctx_scope) ->
        (match use_hash_safe hashes hash_scope with
         | Some commit ->
           store_ctx contexts ctx_scope (S.Commit.tree commit)
         | None ->
           store_ctx contexts ctx_scope (S.Tree.empty ()))

      | Add { key; value; in_ctx_id; out_ctx_id } ->
        let tree = use_ctx_safe contexts in_ctx_id (S.Tree.empty ()) in
        let v = if empty_blobs then "" else value in
        store_ctx contexts out_ctx_id (S.Tree.add tree key v)

      | Remove (key, in_ctx_id, out_ctx_id) ->
        let tree = use_ctx_safe contexts in_ctx_id (S.Tree.empty ()) in
        store_ctx contexts out_ctx_id (S.Tree.remove tree key)

      | Copy { key_src; key_dst; in_ctx_id; out_ctx_id } ->
        let tree = use_ctx_safe contexts in_ctx_id (S.Tree.empty ()) in
        (match S.Tree.find_tree tree key_src with
         | Some sub ->
           store_ctx contexts out_ctx_id
             (S.Tree.add_tree tree key_dst sub)
         | None ->
           store_ctx contexts out_ctx_id tree)

      | Find (key, _, ctx_scope) ->
        let tree = use_ctx_safe contexts ctx_scope (S.Tree.empty ()) in
        ignore (S.Tree.find tree key)

      | Mem (key, _, ctx_scope) ->
        let tree = use_ctx_safe contexts ctx_scope (S.Tree.empty ()) in
        ignore (S.Tree.mem tree key)

      | Mem_tree (key, _, ctx_scope) ->
        let tree = use_ctx_safe contexts ctx_scope (S.Tree.empty ()) in
        ignore (S.Tree.mem_tree tree key)

      | Commit { hash = hash_scope; message = msg; in_ctx_id; _ } ->
        incr commits;
        let tree = use_ctx_safe contexts in_ctx_id (S.Tree.empty ()) in
        let info () =
          S.Info.v ~author:"trace-replay" ~message:msg 0L
        in
        S.set_tree_exn store ~info [] tree;
        (match S.Head.find store with
         | Some c ->
           Hashtbl.replace hashes (unscope hash_scope) c
         | None -> ())
    done;
    (!ops, !commits)

  (** Parallel trace replay by partitioning the trace across workers.

      All workers share the same [repo]. Each worker uses its own branch
      to avoid commit contention. Tree operations (Add, Find, Mem, etc.)
      run in parallel across domains; commits are serialized by irmin-pack's
      batch mechanism.

      @param dm Eio domain manager
      @param ndomains Number of OS domains (cores)
      @param fibers_per_domain Number of concurrent fibers per domain *)
  let replay_parallel ~trace_path ?(max_commits = 0) ?(empty_blobs = false)
      ~ndomains ~fibers_per_domain ~repo ~backend_name ~dm () =
    Printf.printf "  Loading trace into memory...\n%!";
    let rows = load_trace trace_path in
    let nrows = truncate_rows rows max_commits in
    let nworkers = ndomains * fibers_per_domain in
    Printf.printf
      "  Trace: %d operations, %d workers (%d domains × %d fibers)\n%!"
      nrows nworkers ndomains fibers_per_domain;
    let chunk_size = nrows / nworkers in
    let remainder = nrows mod nworkers in
    let domain_results = Array.make ndomains (0, 0) in
    let barrier = Atomic.make ndomains in
    let (), total_time =
      Bench_common.time (fun () ->
        let domain_tasks =
          List.init ndomains (fun did () ->
            Atomic.decr barrier;
            while Atomic.get barrier > 0 do
              Domain.cpu_relax ()
            done;
            let fiber_results = Array.make fibers_per_domain (0, 0) in
            Eio.Fiber.all
              (List.init fibers_per_domain (fun fid () ->
                let worker_id = did * fibers_per_domain + fid in
                let start_idx =
                  worker_id * chunk_size + min worker_id remainder
                in
                let end_idx =
                  start_idx + chunk_size
                  + (if worker_id < remainder then 1 else 0)
                in
                let ops, commits =
                  replay_chunk ~rows ~start_idx ~end_idx ~empty_blobs
                    ~repo ~worker_id ()
                in
                fiber_results.(fid) <- (ops, commits)));
            let total_ops =
              Array.fold_left (fun acc (o, _) -> acc + o) 0 fiber_results
            in
            let total_commits =
              Array.fold_left (fun acc (_, c) -> acc + c) 0 fiber_results
            in
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
      scenario =
        Printf.sprintf "tezos-parallel-%dd×%df"
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
end
