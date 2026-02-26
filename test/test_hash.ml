open Irmin

let test_sha1_hash () =
  let h = Hash.sha1 "hello" in
  let hex = Hash.to_hex h in
  Alcotest.(check string)
    "sha1 hex length" (String.make 40 '0')
    (String.make (String.length hex) '0');
  Alcotest.(check int) "sha1 bytes length" 20 (String.length (Hash.to_bytes h))

let test_sha256_hash () =
  let h = Hash.sha256 "hello" in
  let hex = Hash.to_hex h in
  Alcotest.(check string)
    "sha256 hex length" (String.make 64 '0')
    (String.make (String.length hex) '0');
  Alcotest.(check int)
    "sha256 bytes length" 32
    (String.length (Hash.to_bytes h))

let test_hash_roundtrip () =
  let h1 = Hash.sha1 "test data" in
  let hex = Hash.to_hex h1 in
  match Hash.sha1_of_hex hex with
  | Ok h2 -> Alcotest.(check bool) "roundtrip" true (Hash.equal h1 h2)
  | Error (`Msg msg) -> Alcotest.fail msg

let test_mst_depth () =
  let h = Hash.sha256 "test" in
  let depth = Hash.mst_depth h in
  Alcotest.(check bool) "depth >= 0" true (depth >= 0)

let suite =
  ( "Hash",
    [
      Alcotest.test_case "sha1 hash" `Quick test_sha1_hash;
      Alcotest.test_case "sha256 hash" `Quick test_sha256_hash;
      Alcotest.test_case "hash roundtrip" `Quick test_hash_roundtrip;
      Alcotest.test_case "mst depth" `Quick test_mst_depth;
    ] )
