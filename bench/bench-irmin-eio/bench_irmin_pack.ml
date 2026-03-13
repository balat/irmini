(** Benchmark official Irmin-pack (Eio branch) with persistent backend. *)

module Conf = struct
  let entries = 32
  let stable_hash = 256
  let contents_length_header = Some `Varint
  let inode_child_order = `Seeded_hash
  let forbid_empty_dir_persistence = true
end

module Maker = Irmin_pack_unix.KV (Conf)
module Store = Maker.Make (Irmin.Contents.String)
module B = Bench_irmin_eio.Bench (Store)

let run_all ~sw ~fs conf root =
  let config =
    Irmin_pack.Conf.init ~sw ~fs ~fresh:true Eio.Path.(fs / root)
  in
  let repo = Store.Repo.v config in
  let results = B.run_all ~name:"Irmin-Eio (pack)" conf repo in
  Store.Repo.close repo;
  results

let run_all_parallel ?nfibers ~env conf sw fs root =
  let config =
    Irmin_pack.Conf.init ~sw ~fs ~fresh:true Eio.Path.(fs / root)
  in
  let repo = Store.Repo.v config in
  let large = { conf with Bench_common.value_size = 10_000 } in
  let results =
    [
      B.scenario_commits_parallel ?nfibers ~name:"Irmin-Eio (pack)" ~env conf repo;
      B.scenario_reads_parallel ?nfibers ~name:"Irmin-Eio (pack)" ~env conf repo;
      B.scenario_incremental_parallel ?nfibers ~name:"Irmin-Eio (pack)" ~env conf repo;
      B.scenario_commits_parallel ?nfibers ~name:"Irmin-Eio (pack)" ~env large repo;
      B.scenario_reads_parallel ?nfibers ~name:"Irmin-Eio (pack)" ~env large repo;
      B.scenario_incremental_parallel ?nfibers ~name:"Irmin-Eio (pack)" ~env large repo;
    ]
  in
  Store.Repo.close repo;
  results
