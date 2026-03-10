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

let write_json oc results =
  let escape s =
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
  in
  Printf.fprintf oc "[\n";
  List.iteri
    (fun i r ->
      if i > 0 then Printf.fprintf oc ",\n";
      Printf.fprintf oc
        "  {\"name\": \"%s\", \"scenario\": \"%s\", \"total_ops\": %d, \
         \"total_time\": %.6f, \"ops_per_sec\": %.1f, \"maxrss_kb\": %d}"
        (escape r.name) (escape r.scenario) r.total_ops r.total_time
        r.ops_per_sec r.maxrss_kb)
    results;
  Printf.fprintf oc "\n]\n"

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
