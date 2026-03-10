(** Trace replay benchmark for Irmini.

    Reads Tezos trace files in .repr format (IrmRepBT) and replays the
    recorded operations (Checkout, Add, Remove, Copy, Find, Mem, Commit)
    on an Irmini store. This provides a realistic benchmark based on actual
    Tezos node workloads.

    The .repr binary format is decoded using the [repr] library with the
    same type definitions as the original Irmin trace infrastructure. *)

open Irmin

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

type commit = {
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
  | Commit of commit
[@@deriving repr]

type header = unit [@@deriving repr]

(* ------------------------------------------------------------------ *)
(* Binary file reader                                                  *)
(* ------------------------------------------------------------------ *)

(** Read a varint from a channel (LEB128, same as repr's encoding). *)
let read_varint chan =
  let max_bits = Sys.word_size - 1 in
  let rec aux n p =
    if p >= max_bits then failwith "Failed to decode varint";
    let i = input_char chan |> Char.code in
    let n = n + ((i land 127) lsl p) in
    if i >= 0 && i < 128 then n else aux n (p + 7)
  in
  aux 0 0

(** Read a repr-encoded value prefixed by its varint length. *)
let read_with_prefix decode chan =
  let len = read_varint chan in
  let pos_ref = ref 0 in
  let buf = really_input_string chan len in
  let v = decode buf pos_ref in
  if len <> !pos_ref then
    Printf.ksprintf failwith
      "Trace row expected %d bytes, consumed %d" len !pos_ref;
  v

(** Open a .repr trace file, return header and lazy row sequence. *)
let open_trace path =
  let chan = open_in_bin path in
  let len = LargeFile.in_channel_length chan in
  if len < 12L then begin
    close_in chan;
    Printf.ksprintf failwith "Trace file '%s' too small (%Ld bytes)" path len
  end;
  (* Magic *)
  let magic = really_input_string chan 8 in
  if magic <> "IrmRepBT" then begin
    close_in chan;
    Printf.ksprintf failwith
      "Bad magic in '%s': expected IrmRepBT, got %s" path
      (String.escaped magic)
  end;
  (* Version *)
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
  (* Header *)
  let decode_header = Repr.(decode_bin header_t |> unstage) in
  let _header = read_with_prefix decode_header chan in
  (* Row sequence *)
  let decode_row = Repr.(decode_bin row_t |> unstage) in
  let rec seq () =
    match read_with_prefix decode_row chan with
    | row -> Seq.Cons (row, seq)
    | exception End_of_file -> close_in chan; Seq.Nil
  in
  (chan, seq)

(* ------------------------------------------------------------------ *)
(* Path flattening (Tezos-specific)                                    *)
(* ------------------------------------------------------------------ *)

(** Check if a string is a lowercase hex string of given length. *)
let is_hex len s =
  String.length s = len &&
  let ok = ref true in
  for i = 0 to len - 1 do
    match s.[i] with
    | '0'..'9' | 'a'..'f' -> ()
    | _ -> ok := false
  done;
  !ok

(** Flatten Tezos 6-step hash paths: [aa/bb/cc/dd/ee/xxx...xxx] -> [aabbccddeexxx...xxx]
    where each of the first 5 steps is 2 hex chars and the last is 30 hex chars. *)
let flatten_path path =
  let rec aux prefix = function
    | a :: b :: c :: d :: e :: f :: rest
      when is_hex 2 a && is_hex 2 b && is_hex 2 c
        && is_hex 2 d && is_hex 2 e && is_hex 30 f ->
      let flat = a ^ b ^ c ^ d ^ e ^ f in
      List.rev_append prefix (flat :: rest)
    | step :: rest -> aux (step :: prefix) rest
    | [] -> List.rev prefix
  in
  aux [] path

let flatten_key_in_op = function
  | Checkout _ as op -> op
  | Add a -> Add { a with key = flatten_path a.key }
  | Remove (key, i, o) -> Remove (flatten_path key, i, o)
  | Copy c -> Copy { c with key_src = flatten_path c.key_src;
                             key_dst = flatten_path c.key_dst }
  | Find (key, b, ctx) -> Find (flatten_path key, b, ctx)
  | Mem (key, b, ctx) -> Mem (flatten_path key, b, ctx)
  | Mem_tree (key, b, ctx) -> Mem_tree (flatten_path key, b, ctx)
  | Commit _ as op -> op

(* ------------------------------------------------------------------ *)
(* Scope helpers                                                       *)
(* ------------------------------------------------------------------ *)

let unscope = function Forget x | Keep x -> x

let use_ctx contexts scope =
  let id = unscope scope in
  let ctx = Hashtbl.find contexts id in
  (match scope with Forget _ -> Hashtbl.remove contexts id | Keep _ -> ());
  ctx

let use_hash hashes scope =
  let h = unscope scope in
  let real_h = Hashtbl.find hashes h in
  (match scope with Forget _ -> Hashtbl.remove hashes h | Keep _ -> ());
  real_h

let store_ctx contexts scope tree =
  Hashtbl.replace contexts (unscope scope) tree

(* ------------------------------------------------------------------ *)
(* Replay state                                                        *)
(* ------------------------------------------------------------------ *)

type stats = {
  mutable checkouts : int;
  mutable adds : int;
  mutable removes : int;
  mutable copies : int;
  mutable finds : int;
  mutable mems : int;
  mutable mem_trees : int;
  mutable commits : int;
  mutable find_mismatches : int;
  mutable mem_mismatches : int;
}

let empty_stats () =
  { checkouts = 0; adds = 0; removes = 0; copies = 0;
    finds = 0; mems = 0; mem_trees = 0; commits = 0;
    find_mismatches = 0; mem_mismatches = 0 }

(* ------------------------------------------------------------------ *)
(* Replay engine                                                       *)
(* ------------------------------------------------------------------ *)

(** Replay a trace on an irmini store.

    @param trace_path Path to the .repr trace file
    @param max_commits Stop after this many commits (0 = all)
    @param flatten_paths Apply Tezos path flattening
    @param empty_blobs Replace blob values with empty strings *)
let replay ~trace_path ?(max_commits = 0) ?(flatten_paths = true)
    ?(empty_blobs = false) ?inline_threshold ?inode
    ~(backend : Hash.sha1 Backend.t) () =
  let store = Store.Git.create ~backend () in
  let contexts : (int64, Tree.Git.t) Hashtbl.t = Hashtbl.create 16 in
  let hashes : (string, Hash.sha1) Hashtbl.t = Hashtbl.create 16 in
  let stats = empty_stats () in
  (* Genesis context: id 0 = empty tree *)
  Hashtbl.replace contexts 0L (Tree.Git.empty ());
  let _chan, rows = open_trace trace_path in
  let rows =
    if flatten_paths then Seq.map flatten_key_in_op rows
    else rows
  in
  let commit_count = ref 0 in
  let stop = ref false in
  let exec_op op =
    match op with
    | Checkout (hash_scope, ctx_scope) ->
      stats.checkouts <- stats.checkouts + 1;
      let commit_hash = use_hash hashes hash_scope in
      (match Store.Git.read_commit store commit_hash with
       | Some c ->
         let tree = Store.Git.read_tree store (Commit.Git.tree c) in
         store_ctx contexts ctx_scope tree
       | None ->
         Printf.eprintf "Warning: checkout of unknown commit\n%!";
         store_ctx contexts ctx_scope (Tree.Git.empty ()))

    | Add { key; value; in_ctx_id; out_ctx_id } ->
      stats.adds <- stats.adds + 1;
      let tree = use_ctx contexts in_ctx_id in
      let v = if empty_blobs then "" else value in
      let tree = Tree.Git.add tree key v in
      store_ctx contexts out_ctx_id tree

    | Remove (key, in_ctx_id, out_ctx_id) ->
      stats.removes <- stats.removes + 1;
      let tree = use_ctx contexts in_ctx_id in
      let tree = Tree.Git.remove tree key in
      store_ctx contexts out_ctx_id tree

    | Copy { key_src; key_dst; in_ctx_id; out_ctx_id } ->
      stats.copies <- stats.copies + 1;
      let tree = use_ctx contexts in_ctx_id in
      (match Tree.Git.find_tree tree key_src with
       | Some sub -> store_ctx contexts out_ctx_id (Tree.Git.add_tree tree key_dst sub)
       | None -> store_ctx contexts out_ctx_id tree)

    | Find (key, expected, ctx_scope) ->
      stats.finds <- stats.finds + 1;
      let tree = use_ctx contexts ctx_scope in
      let found = Option.is_some (Tree.Git.find tree key) in
      if found <> expected then
        stats.find_mismatches <- stats.find_mismatches + 1

    | Mem (key, expected, ctx_scope) ->
      stats.mems <- stats.mems + 1;
      let tree = use_ctx contexts ctx_scope in
      let found = Tree.Git.mem tree key in
      if found <> expected then
        stats.mem_mismatches <- stats.mem_mismatches + 1

    | Mem_tree (key, expected, ctx_scope) ->
      stats.mem_trees <- stats.mem_trees + 1;
      let tree = use_ctx contexts ctx_scope in
      let found = Tree.Git.mem_tree tree key in
      if found <> expected then
        stats.mem_mismatches <- stats.mem_mismatches + 1

    | Commit { hash = hash_scope; date = _; message = msg; parents; in_ctx_id } ->
      stats.commits <- stats.commits + 1;
      let tree = use_ctx contexts in_ctx_id in
      (* Resolve parent hashes *)
      let parent_hashes =
        List.map (fun hs -> use_hash hashes hs) parents
      in
      let real_hash =
        Store.Git.commit ?inline_threshold ?inode store ~tree
          ~parents:parent_hashes ~message:msg ~author:"trace-replay"
      in
      Store.Git.set_head store ~branch:"main" real_hash;
      (* Record hash mapping - always store it, Forget/Keep is consumed
         when looking up the hash later (e.g. in Checkout) *)
      Hashtbl.replace hashes (unscope hash_scope) real_hash;
      if max_commits > 0 && stats.commits >= max_commits then
        stop := true;
      commit_count := stats.commits;
      if stats.commits mod 100 = 0 then
        Printf.printf "\r  %d commits replayed%!" stats.commits
  in
  let (), total_time =
    Bench_common.time (fun () ->
      Seq.iter (fun op -> if not !stop then exec_op op) rows)
  in
  if stats.commits >= 100 then Printf.printf "\r";
  let total_ops =
    stats.checkouts + stats.adds + stats.removes + stats.copies +
    stats.finds + stats.mems + stats.mem_trees + stats.commits
  in
  Printf.printf "  Trace replay: %d commits, %d total ops in %.3fs\n%!"
    stats.commits total_ops total_time;
  if stats.find_mismatches > 0 || stats.mem_mismatches > 0 then
    Printf.printf "  Mismatches: find=%d, mem=%d\n%!"
      stats.find_mismatches stats.mem_mismatches;
  {
    Bench_common.name = "Irmini (trace-replay)";
    scenario = Printf.sprintf "tezos-%dcommits" stats.commits;
    total_ops;
    total_time;
    ops_per_sec = Float.of_int total_ops /. total_time;
    details = [
      ("commits", Float.of_int stats.commits);
      ("adds", Float.of_int stats.adds);
      ("finds", Float.of_int stats.finds);
      ("removes", Float.of_int stats.removes);
      ("copies", Float.of_int stats.copies);
      ("mems", Float.of_int stats.mems);
    ];
    maxrss_kb = Bench_common.get_maxrss_kb ();
  }
