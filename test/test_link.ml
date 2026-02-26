open Irmin

let test_link_v_get () =
  let s = Link.Mst.v () in
  let l = Link.v s 42 in
  Alcotest.(check int) "get (v s x) = x" 42 (Link.get l)

let test_link_is_val () =
  let s = Link.Mst.v () in
  let l = Link.v s "hello" in
  Alcotest.(check bool) "in-memory is_val" true (Link.is_val l)

let test_link_equal () =
  let s = Link.Mst.v () in
  let l0 = Link.v s [ 1; 2; 3 ] in
  let l1 = Link.v s [ 1; 2; 3 ] in
  let l2 = Link.v s [ 1; 2; 4 ] in
  Alcotest.(check bool) "same value equal" true (Link.equal l0 l1);
  Alcotest.(check bool) "diff value not equal" false (Link.equal l0 l2)

let test_link_address () =
  let s = Link.Mst.v () in
  let l0 = Link.v s "test" in
  let l1 = Link.v s "test" in
  Alcotest.(check bool) "same address" true (Link.address l0 = Link.address l1)

let test_link_pp () =
  let s = Link.Mst.v () in
  let l = Link.v s "test" in
  let _ = Link.address l in
  let str = Format.asprintf "%a" Link.pp l in
  Alcotest.(check int) "pp is 7 chars" 7 (String.length str)

let test_link_read_write () =
  let s : int Link.store = Link.Mst.v () in
  Link.write s 42;
  Alcotest.(check int) "after write" 42 (Link.read s);
  Link.write s 100;
  Alcotest.(check int) "after second write" 100 (Link.read s)

let test_link_is_open () =
  let s = Link.Mst.v () in
  Alcotest.(check bool) "initially open" true (Link.is_open s);
  Link.close s;
  Alcotest.(check bool) "closed after close" false (Link.is_open s)

type test_tree = test_node Link.t
and test_node = TEmpty | TNode of { l : test_tree; x : int; r : test_tree }

let test_link_tree () =
  let s = Link.Mst.v () in
  let empty = Link.v s TEmpty in
  let leaf x = Link.v s (TNode { l = empty; x; r = empty }) in
  let node l x r = Link.v s (TNode { l; x; r }) in
  let t = node (leaf 1) 2 (leaf 3) in
  match Link.get t with
  | TEmpty -> Alcotest.fail "expected node"
  | TNode n -> (
      Alcotest.(check int) "root" 2 n.x;
      match (Link.get n.l, Link.get n.r) with
      | TNode l, TNode r ->
          Alcotest.(check int) "left" 1 l.x;
          Alcotest.(check int) "right" 3 r.x
      | _ -> Alcotest.fail "expected leaves")

let suite =
  ( "Link",
    [
      Alcotest.test_case "v/get" `Quick test_link_v_get;
      Alcotest.test_case "is_val" `Quick test_link_is_val;
      Alcotest.test_case "equal" `Quick test_link_equal;
      Alcotest.test_case "address" `Quick test_link_address;
      Alcotest.test_case "pp" `Quick test_link_pp;
      Alcotest.test_case "read/write" `Quick test_link_read_write;
      Alcotest.test_case "is_open" `Quick test_link_is_open;
      Alcotest.test_case "tree" `Quick test_link_tree;
    ] )
