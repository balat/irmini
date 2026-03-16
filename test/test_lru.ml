open Irmin

let test_create () =
  let c = Lru.create 10 in
  Alcotest.(check bool) "empty cache" false (Lru.mem c "a")

let test_add_find () =
  let c = Lru.create 10 in
  Lru.add c "a" 1;
  Alcotest.(check (option int)) "find a" (Some 1) (Lru.find c "a");
  Alcotest.(check (option int)) "find b" None (Lru.find c "b")

let test_add_updates_existing () =
  let c = Lru.create 10 in
  Lru.add c "a" 1;
  Lru.add c "a" 2;
  Alcotest.(check (option int)) "updated" (Some 2) (Lru.find c "a");
  (* No duplicate: adding same key shouldn't increase count *)
  Lru.add c "b" 3;
  Alcotest.(check (option int)) "a still there" (Some 2) (Lru.find c "a");
  Alcotest.(check (option int)) "b there" (Some 3) (Lru.find c "b")

let test_eviction () =
  let c = Lru.create 3 in
  Lru.add c "a" 1;
  Lru.add c "b" 2;
  Lru.add c "c" 3;
  (* Cache full: [c, b, a]. Adding d should evict a (LRU). *)
  Lru.add c "d" 4;
  Alcotest.(check (option int)) "a evicted" None (Lru.find c "a");
  Alcotest.(check (option int)) "b still" (Some 2) (Lru.find c "b");
  Alcotest.(check (option int)) "d added" (Some 4) (Lru.find c "d")

let test_find_promotes () =
  let c = Lru.create 3 in
  Lru.add c "a" 1;
  Lru.add c "b" 2;
  Lru.add c "c" 3;
  (* Order: [c, b, a]. Find a → promotes a to front: [a, c, b]. *)
  ignore (Lru.find c "a");
  (* Adding d should now evict b (new LRU), not a. *)
  Lru.add c "d" 4;
  Alcotest.(check (option int)) "a promoted" (Some 1) (Lru.find c "a");
  Alcotest.(check (option int)) "b evicted" None (Lru.find c "b")

let test_capacity_one () =
  let c = Lru.create 1 in
  Lru.add c "a" 1;
  Alcotest.(check (option int)) "a" (Some 1) (Lru.find c "a");
  Lru.add c "b" 2;
  Alcotest.(check (option int)) "a evicted" None (Lru.find c "a");
  Alcotest.(check (option int)) "b" (Some 2) (Lru.find c "b")

let test_clear () =
  let c = Lru.create 10 in
  Lru.add c "a" 1;
  Lru.add c "b" 2;
  Lru.clear c;
  Alcotest.(check (option int)) "a gone" None (Lru.find c "a");
  Alcotest.(check (option int)) "b gone" None (Lru.find c "b");
  Alcotest.(check bool) "mem a" false (Lru.mem c "a");
  (* Can still add after clear *)
  Lru.add c "c" 3;
  Alcotest.(check (option int)) "c works" (Some 3) (Lru.find c "c")

let test_mem () =
  let c = Lru.create 10 in
  Alcotest.(check bool) "empty" false (Lru.mem c "a");
  Lru.add c "a" 1;
  Alcotest.(check bool) "present" true (Lru.mem c "a");
  Alcotest.(check bool) "absent" false (Lru.mem c "b")

let test_eviction_order () =
  (* Verify strict LRU order with a longer sequence *)
  let c = Lru.create 4 in
  Lru.add c "a" 1;
  Lru.add c "b" 2;
  Lru.add c "c" 3;
  Lru.add c "d" 4;
  (* Order: [d, c, b, a]. Touch b → [b, d, c, a]. *)
  ignore (Lru.find c "b");
  (* Add e → evicts a: [e, b, d, c] *)
  Lru.add c "e" 5;
  Alcotest.(check (option int)) "a evicted" None (Lru.find c "a");
  Alcotest.(check bool) "b present" true (Lru.mem c "b");
  Alcotest.(check bool) "c present" true (Lru.mem c "c");
  Alcotest.(check bool) "d present" true (Lru.mem c "d");
  Alcotest.(check bool) "e present" true (Lru.mem c "e")

let test_add_promotes () =
  (* Adding an existing key should promote it (not just update value) *)
  let c = Lru.create 3 in
  Lru.add c "a" 1;
  Lru.add c "b" 2;
  Lru.add c "c" 3;
  (* Order: [c, b, a]. Re-add a with new value → [a, c, b]. *)
  Lru.add c "a" 10;
  (* Add d → should evict b (LRU), not a. *)
  Lru.add c "d" 4;
  Alcotest.(check (option int)) "a promoted+updated" (Some 10) (Lru.find c "a");
  Alcotest.(check (option int)) "b evicted" None (Lru.find c "b")

let suite =
  ( "Lru",
    [
      Alcotest.test_case "create" `Quick test_create;
      Alcotest.test_case "add and find" `Quick test_add_find;
      Alcotest.test_case "add updates existing" `Quick test_add_updates_existing;
      Alcotest.test_case "eviction" `Quick test_eviction;
      Alcotest.test_case "find promotes" `Quick test_find_promotes;
      Alcotest.test_case "capacity one" `Quick test_capacity_one;
      Alcotest.test_case "clear" `Quick test_clear;
      Alcotest.test_case "mem" `Quick test_mem;
      Alcotest.test_case "eviction order" `Quick test_eviction_order;
      Alcotest.test_case "add promotes" `Quick test_add_promotes;
    ] )
