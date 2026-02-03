(** Commit operations delegating to Tree_format. *)

module Make (F : Tree_format.S) = struct
  type hash = F.hash
  type t = F.commit

  let tree = F.commit_tree
  let parents = F.commit_parents
  let author = F.commit_author
  let committer = F.commit_committer
  let message = F.commit_message
  let timestamp = F.commit_timestamp

  let v ~tree ~parents ~author ?(committer = author)
      ?(timestamp = Int64.of_float (Unix.gettimeofday ())) ~message () =
    F.commit_make ~tree ~parents ~author ~committer ~message ~timestamp

  let to_bytes = F.commit_to_bytes
  let of_bytes = F.commit_of_bytes
  let hash = F.commit_hash
end

module Git = Make (Tree_format.Git)
module Mst = Make (Tree_format.Mst)
