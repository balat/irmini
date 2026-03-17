(** State Machine Tests for Irmini backends using QCheck-STM.

    Generates random sequences of read/write/exists operations, executes
    them against both a reference model (association list) and the real
    backend, and verifies consistency — both sequentially and in parallel
    across multiple OS domains. *)

open QCheck
open STM
open Irmin

(* ================================================================== *)
(* STM model for Memory backend (thread_safe_rw)                       *)
(* ================================================================== *)

module Memory_model = struct
  (** SUT = the real backend under test *)
  type sut = Hash.sha1 Backend.t

  (** Model state = simple association list (hash_hex -> data) *)
  type state = (string * string) list

  (** Commands that can be issued to the backend *)
  type cmd =
    | Write of string  (* write data, hash is derived *)
    | Read of string   (* read by data key (we hash it) *)
    | Exists of string (* check existence by data key *)

  let show_cmd = function
    | Write d -> Printf.sprintf "Write(%s)" d
    | Read d -> Printf.sprintf "Read(%s)" d
    | Exists d -> Printf.sprintf "Exists(%s)" d

  let hex_of d = Hash.to_hex (Hash.sha1 d)

  (* Use raw Memory backend (no Eio.Mutex) — STM_domain spawns bare
     Domains without an Eio scheduler, so thread_safe_rw would deadlock. *)
  let init_sut () = Backend.Memory.create_sha1 ()
  let init_state = []
  let cleanup _ = ()

  let arb_cmd _state =
    let data_gen = Gen.map (fun i -> Printf.sprintf "v%d" i) (Gen.int_bound 20) in
    make ~print:show_cmd
      (Gen.oneof [
         Gen.map (fun d -> Write d) data_gen;
         Gen.map (fun d -> Read d) data_gen;
         Gen.map (fun d -> Exists d) data_gen;
       ])

  let next_state cmd state =
    match cmd with
    | Write d ->
        let key = hex_of d in
        if List.mem_assoc key state then state
        else (key, d) :: state
    | Read _ | Exists _ -> state

  let run cmd (sut : sut) =
    match cmd with
    | Write d ->
        let h = Hash.sha1 d in
        Res (unit, sut.write h d)
    | Read d ->
        let h = Hash.sha1 d in
        (* Encode option as string to avoid existential type issues *)
        let v = match sut.read h with None -> "" | Some s -> s in
        Res (string, v)
    | Exists d ->
        let h = Hash.sha1 d in
        Res (int, if sut.exists h then 1 else 0)

  let precond _ _ = true

  let postcond cmd state res =
    match cmd, res with
    | Write _, Res ((Unit, _), ()) -> true
    | Read d, Res ((String, _), r) ->
        let key = hex_of d in
        let expected = match List.assoc_opt key state with None -> "" | Some s -> s in
        String.equal r expected
    | Exists d, Res ((Int, _), r) ->
        let key = hex_of d in
        Int.equal r (if List.mem_assoc key state then 1 else 0)
    | _ -> false
end

module Mem_seq = STM_sequential.Make (Memory_model)
module Mem_dom = STM_domain.Make (Memory_model)

(* ================================================================== *)
(* STM model for LRU cache                                            *)
(* ================================================================== *)

module Lru_model = struct
  type sut = (string, int) Lru.t
  type state = (string * int) list  (* front = MRU, back = LRU *)

  type cmd =
    | Add of string * int
    | Find of string
    | Mem of string
    | Clear

  let max_cap = 8

  let show_cmd = function
    | Add (k, v) -> Printf.sprintf "Add(%s,%d)" k v
    | Find k -> Printf.sprintf "Find(%s)" k
    | Mem k -> Printf.sprintf "Mem(%s)" k
    | Clear -> "Clear"

  let init_sut () = Lru.create max_cap
  let init_state = []
  let cleanup _ = ()

  let arb_cmd _state =
    let key_gen = Gen.map (fun i -> Printf.sprintf "k%d" i) (Gen.int_bound 12) in
    let val_gen = Gen.int_bound 100 in
    make ~print:show_cmd
      (Gen.oneof [
         Gen.map2 (fun k v -> Add (k, v)) key_gen val_gen;
         Gen.map (fun k -> Find k) key_gen;
         Gen.map (fun k -> Mem k) key_gen;
         Gen.pure Clear;
       ])

  let promote k state =
    match List.assoc_opt k state with
    | None -> state
    | Some v -> (k, v) :: List.remove_assoc k state

  let remove_last = function
    | [] -> []
    | l -> match List.rev l with [] -> [] | _ :: rest -> List.rev rest

  let next_state cmd state =
    match cmd with
    | Add (k, v) ->
        let s = List.remove_assoc k state in
        let s = if List.length s >= max_cap then remove_last s else s in
        (k, v) :: s
    | Find k -> promote k state
    | Mem _ -> state
    | Clear -> []

  let run cmd sut =
    match cmd with
    | Add (k, v) -> Res (unit, Lru.add sut k v)
    | Find k ->
        let v = match Lru.find sut k with None -> -1 | Some v -> v in
        Res (int, v)
    | Mem k -> Res (int, if Lru.mem sut k then 1 else 0)
    | Clear -> Res (unit, Lru.clear sut)

  let precond _ _ = true

  let postcond cmd state res =
    match cmd, res with
    | Add _, Res ((Unit, _), _) -> true
    | Find k, Res ((Int, _), r) ->
        let expected = match List.assoc_opt k state with None -> -1 | Some v -> v in
        Int.equal r expected
    | Mem k, Res ((Int, _), r) ->
        Int.equal r (if List.mem_assoc k state then 1 else 0)
    | Clear, Res ((Unit, _), ()) -> true
    | _ -> false
end

module Lru_seq = STM_sequential.Make (Lru_model)

(* ================================================================== *)
(* STM model for Disk backend (uses Eio for I/O)                       *)
(* ================================================================== *)

let rec rm_rf path =
  if Eio.Path.is_directory path then begin
    List.iter (fun n -> rm_rf Eio.Path.(path / n)) (Eio.Path.read_dir path);
    Eio.Path.rmdir path
  end
  else if Eio.Path.is_file path then Eio.Path.unlink path

module Disk_model = struct
  type sut = Hash.sha1 Backend.t

  type state = (string * string) list

  type cmd =
    | Write of string
    | Read of string
    | Exists of string

  let show_cmd = function
    | Write d -> Printf.sprintf "Write(%s)" d
    | Read d -> Printf.sprintf "Read(%s)" d
    | Exists d -> Printf.sprintf "Exists(%s)" d

  let hex_of d = Hash.to_hex (Hash.sha1 d)

  (* These will be set by the test runner before each test *)
  let sw_ref : Eio.Switch.t option ref = ref None
  let cwd_ref : Eio.Fs.dir_ty Eio.Path.t option ref = ref None
  let counter = Atomic.make 0

  let init_sut () =
    let sw = Option.get !sw_ref in
    let cwd = Option.get !cwd_ref in
    let n = Atomic.fetch_and_add counter 1 in
    let root = Eio.Path.(cwd / Printf.sprintf "_stm_disk_%d" n) in
    (try rm_rf root with _ -> ());
    Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 root;
    Backend.Disk.create_sha1 ~use_fsync:false ~sw root

  let init_state = []
  let cleanup sut = sut.Backend.close ()

  let arb_cmd _state =
    let data_gen = Gen.map (fun i -> Printf.sprintf "v%d" i) (Gen.int_bound 15) in
    make ~print:show_cmd
      (Gen.oneof [
         Gen.map (fun d -> Write d) data_gen;
         Gen.map (fun d -> Read d) data_gen;
         Gen.map (fun d -> Exists d) data_gen;
       ])

  let next_state cmd state =
    match cmd with
    | Write d ->
        let key = hex_of d in
        if List.mem_assoc key state then state
        else (key, d) :: state
    | Read _ | Exists _ -> state

  let run cmd (sut : sut) =
    match cmd with
    | Write d ->
        let h = Hash.sha1 d in
        Res (unit, sut.write h d)
    | Read d ->
        let h = Hash.sha1 d in
        let v = match sut.read h with None -> "" | Some s -> s in
        Res (string, v)
    | Exists d ->
        let h = Hash.sha1 d in
        Res (int, if sut.exists h then 1 else 0)

  let precond _ _ = true

  let postcond cmd state res =
    match cmd, res with
    | Write _, Res ((Unit, _), ()) -> true
    | Read d, Res ((String, _), r) ->
        let key = hex_of d in
        let expected = match List.assoc_opt key state with None -> "" | Some s -> s in
        String.equal r expected
    | Exists d, Res ((Int, _), r) ->
        let key = hex_of d in
        Int.equal r (if List.mem_assoc key state then 1 else 0)
    | _ -> false
end

module Disk_seq = STM_sequential.Make (Disk_model)
module Disk_eio = STM_domain_eio.Make (Disk_model)

(* ================================================================== *)
(* Run all STM tests                                                   *)
(* ================================================================== *)

let () =
  let count = 100 in
  Eio_main.run @@ fun env ->
  let cwd = Eio.Stdenv.cwd env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  Eio.Switch.run @@ fun sw ->
  Disk_model.sw_ref := Some sw;
  Disk_model.cwd_ref := Some cwd;
  QCheck_base_runner.run_tests_main
    [
      Mem_seq.agree_test ~count ~name:"Memory backend STM sequential";
      Mem_dom.agree_test_par ~count:5 ~name:"Memory backend STM parallel";
      Lru_seq.agree_test ~count ~name:"LRU STM sequential";
      Disk_seq.agree_test ~count:20 ~name:"Disk backend STM sequential";
      Disk_eio.agree_test_par ~domain_mgr ~count:5
        ~name:"Disk backend STM parallel (Eio)";
    ]
