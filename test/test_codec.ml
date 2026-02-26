open Irmin

let test_git_tree_format () =
  let node = Codec.Git.empty_node in
  Alcotest.(check bool) "empty is empty" true (Codec.Git.is_empty node);
  let h = Hash.sha1 "content" in
  let node = Codec.Git.add node "file.txt" (`Contents h) in
  Alcotest.(check bool) "not empty after add" false (Codec.Git.is_empty node);
  match Codec.Git.find node "file.txt" with
  | Some (`Contents h') ->
      Alcotest.(check bool) "find matches" true (Hash.equal h h')
  | _ -> Alcotest.fail "entry not found"

let test_git_tree_serialization () =
  let h = Hash.sha1 "content" in
  let node = Codec.Git.empty_node in
  let node = Codec.Git.add node "file.txt" (`Contents h) in
  let bytes = Codec.Git.bytes_of_node node in
  match Codec.Git.node_of_bytes bytes with
  | Ok node' ->
      let entries = Codec.Git.list node' in
      Alcotest.(check int) "one entry" 1 (List.length entries)
  | Error (`Msg msg) -> Alcotest.fail msg

let suite =
  ( "Codec",
    [
      Alcotest.test_case "git tree format" `Quick test_git_tree_format;
      Alcotest.test_case "git tree serialization" `Quick
        test_git_tree_serialization;
    ] )
