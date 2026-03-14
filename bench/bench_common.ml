(** Common benchmark harness for comparing Irmin implementations.

    Provides timing, memory tracking, result formatting and comparison tables. *)

type result = {
  name : string;
  scenario : string;
  total_ops : int;
  total_time : float;
  ops_per_sec : float;
  details : (string * float) list;
  maxrss_kb : int;
}

(** Results split by sequential vs parallel, for --output-dir routing. *)
type run_results = {
  sequential : result list;
  parallel : result list;
}

let all_results r = r.sequential @ r.parallel

let time f =
  let t0 = Unix.gettimeofday () in
  let r = f () in
  let t1 = Unix.gettimeofday () in
  (r, t1 -. t0)

let get_maxrss_kb () =
  let ic = open_in "/proc/self/status" in
  let rec scan () =
    match input_line ic with
    | line ->
        if String.length line > 6 && String.sub line 0 6 = "VmRSS:" then begin
          close_in ic;
          Scanf.sscanf line "VmRSS: %d kB" Fun.id
        end
        else scan ()
    | exception End_of_file -> close_in ic; 0
  in
  try scan () with _ -> 0

(** Read a field from /proc/meminfo (in kB). *)
let read_meminfo field =
  try
    let ic = open_in "/proc/meminfo" in
    let rec scan () =
      match input_line ic with
      | line ->
        if String.length line > String.length field
           && String.sub line 0 (String.length field) = field then begin
          close_in ic;
          Scanf.sscanf line (Scanf.format_from_string (field ^ " %d kB") "%d") Fun.id
        end else scan ()
      | exception End_of_file -> close_in ic; 0
    in
    scan ()
  with _ -> 0

(** Available physical memory in kB (RAM not used or reclaimable). *)
let get_available_mem_kb () = read_meminfo "MemAvailable:"

(** Total swap currently used in kB. *)
let get_swap_used_kb () =
  let total = read_meminfo "SwapTotal:" in
  let free = read_meminfo "SwapFree:" in
  total - free

(** Check memory before a benchmark. Prints a warning if available RAM
    is below [needed_kb] and swap is active. Returns true if swap risk. *)
let check_memory ~scenario_name ~needed_kb =
  let avail = get_available_mem_kb () in
  let swap_used = get_swap_used_kb () in
  let avail_mb = avail / 1024 in
  let needed_mb = needed_kb / 1024 in
  if avail < needed_kb then begin
    Format.eprintf
      "@[<v>WARNING: %s needs ~%d MiB but only %d MiB available \
       (swap used: %d MiB).@,\
       Results may be biased by swap I/O. Consider closing other programs \
       or reducing workload.@]@.@."
      scenario_name needed_mb avail_mb (swap_used / 1024);
    true
  end else
    false

let path ~depth n =
  let rec aux acc = function
    | i when i = depth -> List.rev (string_of_int n :: acc)
    | i -> aux (string_of_int i :: acc) (i + 1)
  in
  aux [] 0

let pp_result fmt r =
  Format.fprintf fmt
    "@[<v>=== %s [%s] ===@,\
     total ops:   %d@,\
     total time:  %.3fs@,\
     ops/sec:     %.0f@,\
     maxrss:      %d KiB@]"
    r.name r.scenario r.total_ops r.total_time r.ops_per_sec r.maxrss_kb;
  List.iter
    (fun (k, v) -> Format.fprintf fmt "@,  %-20s %.4fs" k v)
    r.details

let pp_comparison fmt results =
  Format.fprintf fmt "@.@[<v>=== Comparison ===@,";
  Format.fprintf fmt "%-30s %-15s %12s %12s %10s@,"
    "Name" "Scenario" "ops/s" "total(s)" "RSS(MiB)";
  Format.fprintf fmt "%s@,"
    (String.make 82 '-');
  List.iter
    (fun r ->
      Format.fprintf fmt "%-30s %-15s %12.0f %12.3f %10d@,"
        r.name r.scenario r.ops_per_sec r.total_time (r.maxrss_kb / 1024))
    results;
  (* Group by scenario and show relative performance *)
  let scenarios =
    List.sort_uniq String.compare (List.map (fun r -> r.scenario) results)
  in
  List.iter
    (fun scenario ->
      let group = List.filter (fun r -> r.scenario = scenario) results in
      match group with
      | [] | [_] -> ()
      | baseline :: rest ->
          Format.fprintf fmt "@,Relative [%s] (vs %s):@," scenario baseline.name;
          List.iter
            (fun r ->
              let ratio = r.ops_per_sec /. baseline.ops_per_sec in
              Format.fprintf fmt "  %-30s %.2fx@," r.name ratio)
            rest)
    scenarios;
  Format.fprintf fmt "@]@."

type config = {
  ncommits : int;
  tree_add : int;
  depth : int;
  nreads : int;
  value_size : int;
}

let default_config =
  { ncommits = 100; tree_add = 1000; depth = 10; nreads = 10_000;
    value_size = 100 }

let fmt_size n =
  if n >= 1000 then Printf.sprintf "%dK" (n / 1000)
  else Printf.sprintf "%dB" n

let escape_json s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let write_json oc results =
  Printf.fprintf oc "[\n";
  List.iteri
    (fun i r ->
      if i > 0 then Printf.fprintf oc ",\n";
      Printf.fprintf oc
        "  {\"name\": \"%s\", \"scenario\": \"%s\", \"total_ops\": %d, \
         \"total_time\": %.6f, \"ops_per_sec\": %.1f, \"maxrss_kb\": %d}"
        (escape_json r.name) (escape_json r.scenario) r.total_ops r.total_time
        r.ops_per_sec r.maxrss_kb)
    results;
  Printf.fprintf oc "\n]\n"

(** Read results from a JSON file. Returns an empty list if the file
    does not exist or cannot be parsed. *)
let read_json path =
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    (* Minimal JSON array-of-objects parser for our known format *)
    let results = ref [] in
    let i = ref 0 in
    let len = String.length s in
    let skip_ws () =
      while !i < len && (s.[!i] = ' ' || s.[!i] = '\n' || s.[!i] = '\r'
                          || s.[!i] = '\t' || s.[!i] = ',') do
        incr i
      done
    in
    let read_string () =
      (* Expects i to point at opening '"' *)
      assert (s.[!i] = '"');
      incr i;
      let buf = Buffer.create 64 in
      while !i < len && s.[!i] <> '"' do
        if s.[!i] = '\\' then begin incr i; Buffer.add_char buf s.[!i] end
        else Buffer.add_char buf s.[!i];
        incr i
      done;
      incr i; (* skip closing '"' *)
      Buffer.contents buf
    in
    let read_number () =
      let start = !i in
      while !i < len && (s.[!i] >= '0' && s.[!i] <= '9'
                          || s.[!i] = '.' || s.[!i] = '-' || s.[!i] = 'e'
                          || s.[!i] = 'E' || s.[!i] = '+') do
        incr i
      done;
      String.sub s start (!i - start)
    in
    let read_value () =
      skip_ws ();
      if !i < len && s.[!i] = '"' then `String (read_string ())
      else `Number (read_number ())
    in
    (try
       skip_ws ();
       if !i < len && s.[!i] = '[' then incr i;
       while !i < len do
         skip_ws ();
         if !i >= len || s.[!i] = ']' then raise Exit;
         if s.[!i] <> '{' then raise Exit;
         incr i;
         let fields = Hashtbl.create 8 in
         while !i < len && s.[!i] <> '}' do
           skip_ws ();
           if !i < len && s.[!i] = '"' then begin
             let key = read_string () in
             skip_ws ();
             if !i < len && s.[!i] = ':' then incr i;
             let v = read_value () in
             Hashtbl.replace fields key v;
             skip_ws ();
             if !i < len && s.[!i] = ',' then incr i
           end else
             incr i
         done;
         if !i < len then incr i; (* skip '}' *)
         let get_s k = match Hashtbl.find fields k with
           | `String s -> s | `Number s -> s in
         let get_f k = match Hashtbl.find fields k with
           | `Number s -> float_of_string s | `String s -> float_of_string s in
         let get_i k = match Hashtbl.find fields k with
           | `Number s -> int_of_float (float_of_string s) | `String s -> int_of_string s in
         (try
            results := {
              name = get_s "name";
              scenario = get_s "scenario";
              total_ops = get_i "total_ops";
              total_time = get_f "total_time";
              ops_per_sec = get_f "ops_per_sec";
              details = [];
              maxrss_kb = get_i "maxrss_kb";
            } :: !results
          with Not_found -> ());
         skip_ws ()
       done
     with Exit -> ());
    List.rev !results

(** Merge new results into an existing JSON file.
    Replaces entries with matching (name, scenario) keys, keeps the rest. *)
let write_json_merge path new_results =
  let existing = read_json path in
  (* Build a set of (name, scenario) pairs from new results *)
  let new_keys =
    List.fold_left
      (fun acc r -> (r.name, r.scenario) :: acc)
      [] new_results
  in
  (* Keep existing entries whose key is NOT in new results *)
  let kept =
    List.filter
      (fun r -> not (List.exists (fun (n, s) -> n = r.name && s = r.scenario) new_keys))
      existing
  in
  let merged = kept @ new_results in
  let oc = open_out path in
  write_json oc merged;
  close_out oc;
  Format.printf "Merged %d new + %d kept = %d total results into %s@."
    (List.length new_results) (List.length kept) (List.length merged) path

let make_value ~size i =
  let base = Printf.sprintf "value-%d-" i in
  if size <= String.length base then String.sub base 0 size
  else
    let buf = Buffer.create size in
    Buffer.add_string buf base;
    while Buffer.length buf < size do
      Buffer.add_char buf 'x'
    done;
    Buffer.sub buf 0 size
