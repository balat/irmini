(** Persistent pointers to OCaml values. *)

(* Internal representation *)
type 'a location =
  | In_memory of 'a * string
  | At of string (* hash as hex string, algorithm-agnostic *)
  | Both of 'a * string

type 'a t = 'a location ref

(* Effects *)
type _ Effect.t +=
  | Fetch : string -> string Effect.t (* hex hash -> data *)
  | Store : string -> string Effect.t (* data -> hex hash *)

(* Serialization *)
let encode v = Marshal.to_string v [ Marshal.No_sharing ]
let decode s = Marshal.from_string s 0

(* Links *)

let v x =
  let data = encode x in
  ref (In_memory (x, data))

let get l =
  match !l with
  | In_memory (x, _) -> x
  | Both (x, _) -> x
  | At h ->
      let data = Effect.perform (Fetch h) in
      let x = decode data in
      l := Both (x, h);
      x

let is_val l = match !l with In_memory _ | Both _ -> true | At _ -> false

let pp ppf l =
  match !l with
  | In_memory _ -> Format.fprintf ppf "<mem>"
  | At h | Both (_, h) ->
      Format.fprintf ppf "%s" (String.sub h 0 (min 7 (String.length h)))

(* Stores *)

type 'h store = {
  hash_fn : string -> 'h;
  to_hex : 'h -> string;
  of_hex : string -> 'h;
  read : string -> string option; (* hex -> data *)
  write : string -> string -> unit; (* hex -> data -> () *)
  mutable root : Obj.t option; (* type-erased root *)
  mutable open' : bool;
}

let hash s l =
  match !l with
  | In_memory (x, data) ->
      let h = s.hash_fn data in
      let hex = s.to_hex h in
      let _ = Effect.perform (Store data) in
      l := Both (x, hex);
      h
  | At hex -> s.of_hex hex
  | Both (_, hex) -> s.of_hex hex

let equal l0 l1 =
  (* Compare by serialized data for in-memory, by hash otherwise *)
  match (!l0, !l1) with
  | In_memory (_, d0), In_memory (_, d1) -> d0 = d1
  | At h0, At h1 -> h0 = h1
  | Both (_, h0), Both (_, h1) -> h0 = h1
  | At h0, Both (_, h1) | Both (_, h0), At h1 -> h0 = h1
  | In_memory (_, d0), (At h1 | Both (_, h1))
  | (At h1 | Both (_, h1)), In_memory (_, d0) ->
      (* Need to hash to compare - but we don't have store here.
         Fall back to data comparison if both in memory. *)
      ignore (d0, h1);
      false (* Conservative: different if can't compare *)

let mem hash_fn =
  let tbl = Hashtbl.create 128 in
  {
    hash_fn;
    to_hex = (fun h -> Marshal.to_string h []);
    (* placeholder *)
    of_hex = (fun s -> Marshal.from_string s 0);
    read = Hashtbl.find_opt tbl;
    write = Hashtbl.replace tbl;
    root = None;
    open' = true;
  }

let mem_sha256 () =
  let tbl = Hashtbl.create 128 in
  {
    hash_fn = Hash.sha256;
    to_hex = Hash.to_hex;
    of_hex =
      (fun s ->
        match Hash.sha256_of_hex s with
        | Ok h -> h
        | Error _ -> failwith "invalid hash");
    read = Hashtbl.find_opt tbl;
    write = Hashtbl.replace tbl;
    root = None;
    open' = true;
  }

let mem_sha1 () =
  let tbl = Hashtbl.create 128 in
  {
    hash_fn = Hash.sha1;
    to_hex = Hash.to_hex;
    of_hex =
      (fun s ->
        match Hash.sha1_of_hex s with
        | Ok h -> h
        | Error _ -> failwith "invalid hash");
    read = Hashtbl.find_opt tbl;
    write = Hashtbl.replace tbl;
    root = None;
    open' = true;
  }

let run (type h a) (s : h store) (f : unit -> a) : a =
  if not s.open' then failwith "Link.run: store is closed";
  let open Effect.Deep in
  try_with f ()
    {
      effc =
        (fun (type c) (eff : c Effect.t) ->
          match eff with
          | Fetch hex ->
              Some
                (fun (k : (c, _) continuation) ->
                  match s.read hex with
                  | None ->
                      failwith
                        (Printf.sprintf "Link.get: hash not found: %s" hex)
                  | Some data -> continue k data)
          | Store data ->
              Some
                (fun (k : (c, _) continuation) ->
                  let h = s.hash_fn data in
                  let hex = s.to_hex h in
                  s.write hex data;
                  continue k hex)
          | _ -> None);
    }

let root (type h a) (s : h store) : a option = Option.map Obj.obj s.root

let set_root (type h a) (s : h store) (x : a) : unit =
  if not s.open' then failwith "Link.set_root: store is closed";
  s.root <- Some (Obj.repr x)

let is_open s = s.open'
let close s = s.open' <- false
