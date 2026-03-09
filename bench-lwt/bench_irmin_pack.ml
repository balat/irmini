(** Benchmark official Irmin-Lwt with irmin-pack backend. *)

module Conf = struct
  let entries = 32
  let stable_hash = 256
  let contents_length_header = Some `Varint
  let inode_child_order = `Seeded_hash
  let forbid_empty_dir_persistence = true
end

module Maker = Irmin_pack_unix.KV (Conf)
module Store = Maker.Make (Irmin.Contents.String)
module B = Bench_irmin_lwt.Bench (Store)

let run_all conf root =
  Lwt_main.run
    (let open Lwt.Syntax in
    let config = Irmin_pack.config root in
    let* repo = Store.Repo.v config in
    let* results = B.run_all ~name:"Irmin-Lwt (pack)" conf repo in
    let* () = Store.Repo.close repo in
    Lwt.return results)
