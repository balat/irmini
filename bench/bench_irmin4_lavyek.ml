(** Benchmark Irmin4 with Lavyek backend across all scenarios.

    Each scenario gets a fresh Lavyek store in a separate subdirectory
    to avoid WAL replay issues between runs. *)

let run_all ?inline_threshold ?inode ?(cache = 0) ?use_fsync
    ?ndomains ?fibers_per_domain ?parallel_only ?scenarios ?name:custom_name
    ~sw ~env root (conf : Bench_common.config) =
  let name = match custom_name with
    | Some n -> n
    | None ->
      let suffix = if cache > 0 then "+cache" else "" in
      "Irmini" ^ suffix ^ " (lavyek)" in
  let n = ref 0 in
  let mk () =
    incr n;
    let subdir = Eio.Path.(root / Printf.sprintf "scenario_%d" !n) in
    let cache = if cache > 0 then Some cache else None in
    Irmin_lavyek.create ?cache ?use_fsync ~sw subdir
  in
  let mk_backend () = mk () in
  let mk_backend_ts () = mk () in
  let close (backend : Irmin.Hash.sha1 Irmin.Backend.t) = backend.close () in
  Bench_irmin4.run_scenarios ?inline_threshold ?inode ?ndomains ?fibers_per_domain
    ?parallel_only ?scenarios ~mk_backend ~mk_backend_ts ~close ~name ~env conf
