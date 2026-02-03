module Make (F : Tree_format.S) = struct
  type hash = F.hash

  type t = {
    tree : hash;
    parents : hash list;
    author : string;
    committer : string;
    message : string;
    timestamp : int64;
  }

  let tree c = c.tree
  let parents c = c.parents
  let author c = c.author
  let committer c = c.committer
  let message c = c.message
  let timestamp c = c.timestamp

  let v ~tree ~parents ~author ?(committer = author)
      ?(timestamp = Int64.of_float (Unix.gettimeofday ())) ~message () =
    { tree; parents; author; committer; message; timestamp }

  (* Git commit format:
     tree <sha1>
     parent <sha1>  (zero or more)
     author <name> <email> <timestamp> <tz>
     committer <name> <email> <timestamp> <tz>

     <message> *)
  let to_bytes c =
    let buf = Buffer.create 256 in
    Buffer.add_string buf "tree ";
    Buffer.add_string buf (Hash.to_hex c.tree);
    Buffer.add_char buf '\n';
    List.iter
      (fun parent ->
        Buffer.add_string buf "parent ";
        Buffer.add_string buf (Hash.to_hex parent);
        Buffer.add_char buf '\n')
      c.parents;
    Buffer.add_string buf "author ";
    Buffer.add_string buf c.author;
    Buffer.add_string buf " ";
    Buffer.add_string buf (Int64.to_string c.timestamp);
    Buffer.add_string buf " +0000\n";
    Buffer.add_string buf "committer ";
    Buffer.add_string buf c.committer;
    Buffer.add_string buf " ";
    Buffer.add_string buf (Int64.to_string c.timestamp);
    Buffer.add_string buf " +0000\n";
    Buffer.add_char buf '\n';
    Buffer.add_string buf c.message;
    Buffer.contents buf

  let hash c =
    let data = to_bytes c in
    let header = Printf.sprintf "commit %d\x00" (String.length data) in
    F.hash_contents (header ^ data)

  let parse_hex_hash s =
    (* This is simplified - real implementation would use proper parsing *)
    match Hash.sha1_of_hex s with
    | Ok h -> Ok (Obj.magic h : hash)
    | Error e -> Error e

  let of_bytes data =
    (* Simplified parser - real implementation would be more robust *)
    let lines = String.split_on_char '\n' data in
    let rec parse_headers lines tree parents author committer =
      match lines with
      | [] -> Error (`Msg "unexpected end of commit")
      | "" :: rest -> (
          (* Empty line marks start of message *)
          let message = String.concat "\n" rest in
          match tree with
          | None -> Error (`Msg "missing tree")
          | Some tree ->
              Ok
                {
                  tree;
                  parents = List.rev parents;
                  author = Option.value author ~default:"unknown";
                  committer = Option.value committer ~default:"unknown";
                  message;
                  timestamp = 0L;
                })
      | line :: rest ->
          if String.length line >= 5 && String.sub line 0 5 = "tree " then
            let hex = String.sub line 5 (String.length line - 5) in
            match parse_hex_hash hex with
            | Ok h -> parse_headers rest (Some h) parents author committer
            | Error _ as e -> e
          else if String.length line >= 7 && String.sub line 0 7 = "parent "
          then
            let hex = String.sub line 7 (String.length line - 7) in
            match parse_hex_hash hex with
            | Ok h -> parse_headers rest tree (h :: parents) author committer
            | Error _ as e -> e
          else if String.length line >= 7 && String.sub line 0 7 = "author "
          then
            let author_str = String.sub line 7 (String.length line - 7) in
            parse_headers rest tree parents (Some author_str) committer
          else if
            String.length line >= 10 && String.sub line 0 10 = "committer "
          then
            let committer_str = String.sub line 10 (String.length line - 10) in
            parse_headers rest tree parents author (Some committer_str)
          else parse_headers rest tree parents author committer
    in
    parse_headers lines None [] None None
end

module Git = Make (Tree_format.Git)
module Mst = Make (Tree_format.Mst)
