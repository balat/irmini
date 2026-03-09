type ('k, 'v) node = {
  key : 'k;
  mutable value : 'v;
  mutable prev : ('k, 'v) node option;
  mutable next : ('k, 'v) node option;
}

type ('k, 'v) t = {
  capacity : int;
  tbl : ('k, ('k, 'v) node) Hashtbl.t;
  mutable head : ('k, 'v) node option;
  mutable tail : ('k, 'v) node option;
  mutable length : int;
}

let create capacity =
  { capacity; tbl = Hashtbl.create capacity; head = None; tail = None; length = 0 }

let detach t node =
  (match node.prev with
  | Some p -> p.next <- node.next
  | None -> t.head <- node.next);
  (match node.next with
  | Some n -> n.prev <- node.prev
  | None -> t.tail <- node.prev);
  node.prev <- None;
  node.next <- None

let push_front t node =
  node.prev <- None;
  node.next <- t.head;
  (match t.head with Some h -> h.prev <- Some node | None -> ());
  t.head <- Some node;
  if t.tail = None then t.tail <- Some node

let find t key =
  match Hashtbl.find_opt t.tbl key with
  | None -> None
  | Some node ->
      detach t node;
      push_front t node;
      Some node.value

let evict_lru t =
  match t.tail with
  | None -> ()
  | Some node ->
      detach t node;
      Hashtbl.remove t.tbl node.key;
      t.length <- t.length - 1

let add t key value =
  match Hashtbl.find_opt t.tbl key with
  | Some node ->
      node.value <- value;
      detach t node;
      push_front t node
  | None ->
      if t.length >= t.capacity then evict_lru t;
      let node = { key; value; prev = None; next = None } in
      Hashtbl.replace t.tbl key node;
      push_front t node;
      t.length <- t.length + 1

let mem t key = Hashtbl.mem t.tbl key

let clear t =
  Hashtbl.clear t.tbl;
  t.head <- None;
  t.tail <- None;
  t.length <- 0
