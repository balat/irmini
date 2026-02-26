open Irmin

let test_commit_fields () =
  let tree_hash = Hash.sha1 "tree content" in
  let c =
    Commit.Git.v ~tree:tree_hash ~parents:[] ~author:"Alice"
      ~message:"Initial commit" ()
  in
  Alcotest.(check string) "author" "Alice" (Commit.Git.author c);
  Alcotest.(check string) "message" "Initial commit" (Commit.Git.message c);
  Alcotest.(check (list (Alcotest.testable Hash.pp Hash.equal)))
    "no parents" [] (Commit.Git.parents c);
  Alcotest.(check bool)
    "tree matches" true
    (Hash.equal tree_hash (Commit.Git.tree c))

let test_commit_committer () =
  let tree_hash = Hash.sha1 "tree" in
  let c =
    Commit.Git.v ~tree:tree_hash ~parents:[] ~author:"Alice" ~committer:"Bob"
      ~message:"test" ()
  in
  Alcotest.(check string) "committer" "Bob" (Commit.Git.committer c)

let test_commit_parents () =
  let tree_hash = Hash.sha1 "tree" in
  let parent1 = Hash.sha1 "parent1" in
  let parent2 = Hash.sha1 "parent2" in
  let c =
    Commit.Git.v ~tree:tree_hash ~parents:[ parent1; parent2 ] ~author:"test"
      ~message:"merge" ()
  in
  Alcotest.(check int) "two parents" 2 (List.length (Commit.Git.parents c))

let test_commit_roundtrip () =
  let tree_hash = Hash.sha1 "tree content" in
  let c =
    Commit.Git.v ~tree:tree_hash ~parents:[] ~author:"Alice"
      ~message:"test commit" ()
  in
  let bytes = Commit.Git.to_bytes c in
  match Commit.Git.of_bytes bytes with
  | Ok c' ->
      Alcotest.(check string) "author roundtrip" "Alice" (Commit.Git.author c');
      Alcotest.(check string)
        "message roundtrip" "test commit" (Commit.Git.message c')
  | Error (`Msg msg) -> Alcotest.fail msg

let test_commit_hash () =
  let tree_hash = Hash.sha1 "tree" in
  let c1 =
    Commit.Git.v ~tree:tree_hash ~parents:[] ~author:"Alice" ~message:"same"
      ~timestamp:1000L ()
  in
  let c2 =
    Commit.Git.v ~tree:tree_hash ~parents:[] ~author:"Alice" ~message:"same"
      ~timestamp:1000L ()
  in
  Alcotest.(check bool)
    "same content same hash" true
    (Hash.equal (Commit.Git.hash c1) (Commit.Git.hash c2))

let suite =
  ( "Commit",
    [
      Alcotest.test_case "fields" `Quick test_commit_fields;
      Alcotest.test_case "committer" `Quick test_commit_committer;
      Alcotest.test_case "parents" `Quick test_commit_parents;
      Alcotest.test_case "roundtrip" `Quick test_commit_roundtrip;
      Alcotest.test_case "hash" `Quick test_commit_hash;
    ] )
