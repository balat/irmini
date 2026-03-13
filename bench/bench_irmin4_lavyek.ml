(** Benchmark Irmin4 with Lavyek backend across all scenarios.

    Each scenario gets a fresh Lavyek store in a separate subdirectory
    to avoid WAL replay issues between runs. *)

let run_all ?inline_threshold ?inode ?(cache = 100_000) ?nfibers ?scenarios ?name:custom_name ~sw ~env root (conf : Bench_common.config) =
  let name = match custom_name with
    | Some n -> n
    | None -> "Irmini (lavyek)" in
  let n = ref 0 in
  let mk () =
    incr n;
    let subdir = Eio.Path.(root / Printf.sprintf "scenario_%d" !n) in
    let b = Irmin_lavyek.create ~sw subdir in
    if cache > 0 then Irmin.Backend.cached ~capacity:cache b else b
  in
  let mk_backend () = mk () in
  let mk_backend_ts () = Irmin.Backend.thread_safe (mk ()) in
  let close (backend : Irmin.Hash.sha1 Irmin.Backend.t) = backend.close () in
  Bench_irmin4.run_scenarios ?nfibers ?inline_threshold ?inode ?scenarios
    ~mk_backend ~mk_backend_ts ~close ~name ~env conf
