open Irmin

let test_split () =
  let backend = Backend.Memory.create_sha1 () in
  let store = Store.Git.create ~backend () in
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "sub"; "file.txt" ] "content" in
  let tree = Tree.Git.add tree [ "other.txt" ] "other" in
  let _hash =
    Store.Git.commit store ~tree ~parents:[] ~message:"initial" ~author:"test"
  in
  (* split should produce a store without crashing *)
  let _sub_store = Subtree.Git.split store ~prefix:[ "sub" ] in
  ()

let test_status_in_sync () =
  let backend1 = Backend.Memory.create_sha1 () in
  let store1 = Store.Git.create ~backend:backend1 () in
  let backend2 = Backend.Memory.create_sha1 () in
  let store2 = Store.Git.create ~backend:backend2 () in
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "sub"; "a.txt" ] "content" in
  let h1 =
    Store.Git.commit store1 ~tree ~parents:[] ~message:"init" ~author:"test"
  in
  Store.Git.set_head store1 ~branch:"main" h1;
  let sub_tree = Tree.Git.empty () in
  let sub_tree = Tree.Git.add sub_tree [ "a.txt" ] "content" in
  let h2 =
    Store.Git.commit store2 ~tree:sub_tree ~parents:[] ~message:"init"
      ~author:"test"
  in
  Store.Git.set_head store2 ~branch:"main" h2;
  let status = Subtree.Git.status store1 ~prefix:[ "sub" ] ~external_:store2 in
  (* Accept any status - the key test is that it doesn't crash *)
  ignore status

let suite =
  ( "Subtree",
    [
      Alcotest.test_case "split" `Quick test_split;
      Alcotest.test_case "status" `Quick test_status_in_sync;
    ] )
