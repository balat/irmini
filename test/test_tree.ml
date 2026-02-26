open Irmin

let test_empty_tree () =
  let tree = Tree.Git.empty () in
  Alcotest.(check (option string))
    "find empty" None
    (Tree.Git.find tree [ "foo" ])

let test_tree_add_find () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "foo"; "bar" ] "content" in
  Alcotest.(check (option string))
    "find added" (Some "content")
    (Tree.Git.find tree [ "foo"; "bar" ])

let test_tree_remove () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "foo" ] "content" in
  let tree = Tree.Git.remove tree [ "foo" ] in
  Alcotest.(check (option string))
    "find removed" None
    (Tree.Git.find tree [ "foo" ])

let test_tree_overwrite () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "key" ] "value1" in
  let tree = Tree.Git.add tree [ "key" ] "value2" in
  Alcotest.(check (option string))
    "find overwritten" (Some "value2")
    (Tree.Git.find tree [ "key" ])

let test_tree_nested () =
  let tree = Tree.Git.empty () in
  let tree = Tree.Git.add tree [ "a"; "b"; "c" ] "deep" in
  let tree = Tree.Git.add tree [ "a"; "x" ] "shallow" in
  Alcotest.(check (option string))
    "find deep" (Some "deep")
    (Tree.Git.find tree [ "a"; "b"; "c" ]);
  Alcotest.(check (option string))
    "find shallow" (Some "shallow")
    (Tree.Git.find tree [ "a"; "x" ])

let suite =
  ( "Tree",
    [
      Alcotest.test_case "empty tree" `Quick test_empty_tree;
      Alcotest.test_case "tree add/find" `Quick test_tree_add_find;
      Alcotest.test_case "tree remove" `Quick test_tree_remove;
      Alcotest.test_case "tree overwrite" `Quick test_tree_overwrite;
      Alcotest.test_case "tree nested" `Quick test_tree_nested;
    ] )
