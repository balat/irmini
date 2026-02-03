(** Demonstrate MST proof generation and verification. *)

open Irmin

let () =
  (* Create in-memory backend *)
  let backend = Backend.Memory.create_sha256 () in

  (* Build a tree with ATProto-style keys (flat namespace) *)
  let tree = Tree.Mst.empty () in
  let tree = Tree.Mst.add tree [ "post/3k2yihx" ] "Hello World" in
  let tree =
    Tree.Mst.add tree [ "profile/self" ] "{\"displayName\":\"Alice\"}"
  in
  let tree =
    Tree.Mst.add tree [ "like/3k2yihy" ] "{\"subject\":\"at://...\"}"
  in
  let root = Tree.Mst.hash tree ~backend in

  Printf.printf "MST Root: %s\n" (String.sub (Hash.to_hex root) 0 16);
  Printf.printf "\n";

  (* Produce a proof for reading a post *)
  let path = [ "post/3k2yihx" ] in
  let proof, result =
    Proof.Mst.produce backend root (fun t ->
        let v = Proof.Mst.Tree.find t path in
        (t, v))
  in

  Printf.printf "Proof for: %s\n" (List.hd path);
  Printf.printf "Value: %s\n" (Option.value ~default:"<not found>" result);
  Printf.printf "\n";

  (* Show proof hashes *)
  let hash_str h = String.sub (Hash.to_hex h) 0 16 in
  let before_hash =
    match Proof.before proof with
    | `Node h -> hash_str h
    | `Contents h -> hash_str h
  in
  let after_hash =
    match Proof.after proof with
    | `Node h -> hash_str h
    | `Contents h -> hash_str h
  in
  Printf.printf "Before: %s (read-only, no change)\n" before_hash;
  Printf.printf "After:  %s\n" after_hash;
  Printf.printf "\n";

  (* Verify without backend - proof contains all needed data *)
  Printf.printf "Verifying proof (no backend access)...\n";
  match
    Proof.Mst.verify proof (fun t ->
        let v = Proof.Mst.Tree.find t path in
        (t, v))
  with
  | Ok (_, v) ->
      Printf.printf "✓ Verified: %s\n" (Option.value ~default:"<none>" v)
  | Error (`Proof_mismatch msg) -> Printf.printf "✗ Invalid: %s\n" msg
