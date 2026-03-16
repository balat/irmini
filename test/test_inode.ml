open Irmin

module Inode = Inode.Make (Codec.Git)

let backend () = Backend.Memory.create_sha1 ()

let make_entry v = `Contents (Codec.Git.hash_contents v)

let make_entries n =
  List.init n (fun i ->
      let name = Printf.sprintf "entry-%04d" i in
      (name, make_entry (Printf.sprintf "value-%d" i)))

(* --- Basic operations --- *)

let test_empty () =
  let b = backend () in
  let h = Inode.write [] ~backend:b in
  let entries = Inode.list_all ~backend:b h in
  Alcotest.(check int) "empty" 0 (List.length entries)

let test_single_entry () =
  let b = backend () in
  let entries = make_entries 1 in
  let h = Inode.write entries ~backend:b in
  let found = Inode.find ~backend:b h "entry-0000" in
  Alcotest.(check bool) "found" true (Option.is_some found);
  let all = Inode.list_all ~backend:b h in
  Alcotest.(check int) "count" 1 (List.length all)

let test_below_threshold () =
  (* 32 entries = max_entries, should stay flat (no inode split) *)
  let b = backend () in
  let entries = make_entries 32 in
  let h = Inode.write entries ~backend:b in
  let all = Inode.list_all ~backend:b h in
  Alcotest.(check int) "count" 32 (List.length all);
  (* Verify the data is a flat node, not an inode *)
  let data = Option.get (b.read h) in
  Alcotest.(check bool) "flat node" false (Inode.is_inode data)

let test_above_threshold () =
  (* 33 entries > max_entries, should split into inode trie *)
  let b = backend () in
  let entries = make_entries 33 in
  let h = Inode.write entries ~backend:b in
  let all = Inode.list_all ~backend:b h in
  Alcotest.(check int) "count" 33 (List.length all);
  (* Root should be an inode *)
  let data = Option.get (b.read h) in
  Alcotest.(check bool) "inode root" true (Inode.is_inode data)

(* --- Find --- *)

let test_find_all () =
  let b = backend () in
  let entries = make_entries 100 in
  let h = Inode.write entries ~backend:b in
  List.iter (fun (name, entry) ->
      let found = Inode.find ~backend:b h name in
      Alcotest.(check bool) (Printf.sprintf "find %s" name) true
        (found = Some entry))
    entries

let test_find_missing () =
  let b = backend () in
  let entries = make_entries 50 in
  let h = Inode.write entries ~backend:b in
  let found = Inode.find ~backend:b h "nonexistent" in
  Alcotest.(check bool) "not found" true (Option.is_none found)

(* --- list_all roundtrip --- *)

let test_roundtrip_small () =
  let b = backend () in
  let entries = make_entries 10 in
  let h = Inode.write entries ~backend:b in
  let recovered = Inode.list_all ~backend:b h in
  let sorted_orig = List.sort compare entries in
  let sorted_recv = List.sort compare recovered in
  Alcotest.(check int) "same count" (List.length entries) (List.length recovered);
  List.iter2 (fun (n1, e1) (n2, e2) ->
      Alcotest.(check string) "name" n1 n2;
      Alcotest.(check bool) "entry" true (e1 = e2))
    sorted_orig sorted_recv

let test_roundtrip_large () =
  let b = backend () in
  let entries = make_entries 200 in
  let h = Inode.write entries ~backend:b in
  let recovered = Inode.list_all ~backend:b h in
  Alcotest.(check int) "count" 200 (List.length recovered);
  (* Verify every entry can be found *)
  List.iter (fun (name, _) ->
      Alcotest.(check bool) name true
        (Option.is_some (Inode.find ~backend:b h name)))
    entries

(* --- Incremental update --- *)

let test_update_add () =
  let b = backend () in
  let entries = make_entries 50 in
  let h = Inode.write entries ~backend:b in
  let new_entry = ("new-entry", make_entry "new-value") in
  let h2 = Inode.update ~backend:b h
      ~additions:[new_entry] ~removals:[] in
  let all = Inode.list_all ~backend:b h2 in
  Alcotest.(check int) "count" 51 (List.length all);
  Alcotest.(check bool) "new found" true
    (Option.is_some (Inode.find ~backend:b h2 "new-entry"))

let test_update_remove () =
  let b = backend () in
  let entries = make_entries 50 in
  let h = Inode.write entries ~backend:b in
  let h2 = Inode.update ~backend:b h
      ~additions:[] ~removals:["entry-0000"; "entry-0001"] in
  let all = Inode.list_all ~backend:b h2 in
  Alcotest.(check int) "count" 48 (List.length all);
  Alcotest.(check bool) "removed 0" true
    (Option.is_none (Inode.find ~backend:b h2 "entry-0000"));
  Alcotest.(check bool) "removed 1" true
    (Option.is_none (Inode.find ~backend:b h2 "entry-0001"));
  (* Others still present *)
  Alcotest.(check bool) "kept 2" true
    (Option.is_some (Inode.find ~backend:b h2 "entry-0002"))

let test_update_add_and_remove () =
  let b = backend () in
  let entries = make_entries 50 in
  let h = Inode.write entries ~backend:b in
  let new_entry = ("replacement", make_entry "new") in
  let h2 = Inode.update ~backend:b h
      ~additions:[new_entry] ~removals:["entry-0000"] in
  let all = Inode.list_all ~backend:b h2 in
  Alcotest.(check int) "count" 50 (List.length all);
  Alcotest.(check bool) "old gone" true
    (Option.is_none (Inode.find ~backend:b h2 "entry-0000"));
  Alcotest.(check bool) "new present" true
    (Option.is_some (Inode.find ~backend:b h2 "replacement"))

(* --- Structural sharing --- *)

let test_structural_sharing () =
  (* Update should reuse unchanged subtrees *)
  let b = backend () in
  let entries = make_entries 100 in
  let h1 = Inode.write entries ~backend:b in
  (* Modify just one entry *)
  let h2 = Inode.update ~backend:b h1
      ~additions:[("entry-0050", make_entry "modified")] ~removals:[] in
  (* Root hashes differ *)
  Alcotest.(check bool) "different roots" true
    (Codec.Git.hash_to_hex h1 <> Codec.Git.hash_to_hex h2);
  (* But unchanged entries should still be findable via h1 *)
  Alcotest.(check bool) "h1 entry-0000" true
    (Option.is_some (Inode.find ~backend:b h1 "entry-0000"));
  Alcotest.(check bool) "h2 entry-0000" true
    (Option.is_some (Inode.find ~backend:b h2 "entry-0000"))

(* --- Determinism --- *)

let test_deterministic () =
  (* Writing the same entries twice should produce the same hash *)
  let b1 = backend () in
  let b2 = backend () in
  let entries = make_entries 100 in
  let h1 = Inode.write entries ~backend:b1 in
  let h2 = Inode.write entries ~backend:b2 in
  Alcotest.(check string) "same hash"
    (Codec.Git.hash_to_hex h1) (Codec.Git.hash_to_hex h2)

(* --- Large scale --- *)

let test_large_1000 () =
  let b = backend () in
  let entries = make_entries 1000 in
  let h = Inode.write entries ~backend:b in
  let all = Inode.list_all ~backend:b h in
  Alcotest.(check int) "1000 entries" 1000 (List.length all);
  (* Spot check *)
  Alcotest.(check bool) "find 500" true
    (Option.is_some (Inode.find ~backend:b h "entry-0500"))

let suite =
  ( "Inode",
    [
      Alcotest.test_case "empty" `Quick test_empty;
      Alcotest.test_case "single entry" `Quick test_single_entry;
      Alcotest.test_case "below threshold (32)" `Quick test_below_threshold;
      Alcotest.test_case "above threshold (33)" `Quick test_above_threshold;
      Alcotest.test_case "find all (100)" `Quick test_find_all;
      Alcotest.test_case "find missing" `Quick test_find_missing;
      Alcotest.test_case "roundtrip small (10)" `Quick test_roundtrip_small;
      Alcotest.test_case "roundtrip large (200)" `Quick test_roundtrip_large;
      Alcotest.test_case "update add" `Quick test_update_add;
      Alcotest.test_case "update remove" `Quick test_update_remove;
      Alcotest.test_case "update add and remove" `Quick test_update_add_and_remove;
      Alcotest.test_case "structural sharing" `Quick test_structural_sharing;
      Alcotest.test_case "deterministic" `Quick test_deterministic;
      Alcotest.test_case "large scale (1000)" `Quick test_large_1000;
    ] )
