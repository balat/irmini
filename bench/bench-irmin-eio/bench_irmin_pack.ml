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
