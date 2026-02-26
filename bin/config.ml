(** Irmin CLI configuration. *)

type backend = Git | Mst | Memory
type t = { backend : backend; store_path : string; default_branch : string }

let default = { backend = Git; store_path = "."; default_branch = "main" }

let pp_backend ppf = function
  | Git -> Fmt.string ppf "git"
  | Mst -> Fmt.string ppf "mst"
  | Memory -> Fmt.string ppf "memory"

let backend_of_string = function
  | "git" -> Some Git
  | "mst" | "atproto" -> Some Mst
  | "memory" | "mem" -> Some Memory
  | _ -> None

(** Parse config file. Format: key = value, one per line. *)
let parse_config_file path =
  if not (Sys.file_exists path) then None
  else
    let ic = open_in path in
    let rec loop acc =
      match input_line ic with
      | line ->
          let line = String.trim line in
          if line = "" || line.[0] = '#' then loop acc
          else begin
            match String.index_opt line '=' with
            | None -> loop acc
            | Some i ->
                let key = String.trim (String.sub line 0 i) in
                let value =
                  String.trim
                    (String.sub line (i + 1) (String.length line - i - 1))
                in
                loop ((key, value) :: acc)
          end
      | exception End_of_file ->
          close_in ic;
          Some acc
    in
    loop []

let of_pairs pairs =
  List.fold_left
    (fun cfg (key, value) ->
      match key with
      | "backend" -> (
          match backend_of_string value with
          | Some b -> { cfg with backend = b }
          | None -> cfg)
      | "store" | "store_path" | "path" -> { cfg with store_path = value }
      | "branch" | "default_branch" -> { cfg with default_branch = value }
      | _ -> cfg)
    default pairs

(** Detect backend from directory structure. *)
let detect_backend ~cwd =
  let git_dir = Filename.concat cwd ".git" in
  let irmin_dir = Filename.concat cwd ".irmin" in
  if Sys.file_exists git_dir && Sys.is_directory git_dir then
    Some { default with backend = Git; store_path = cwd }
  else if Sys.file_exists irmin_dir && Sys.is_directory irmin_dir then
    (* Check for config in .irmin/ *)
    let config_path = Filename.concat irmin_dir "config" in
    match parse_config_file config_path with
    | Some pairs -> Some (of_pairs pairs)
    | None -> Some { default with backend = Mst; store_path = irmin_dir }
  else None

(** Load configuration. Priority: explicit config > .irmin/config > auto-detect
    > default *)
let load ?config_file ~repo () =
  (* First try explicit config file *)
  match config_file with
  | Some path -> (
      match parse_config_file path with
      | Some pairs -> of_pairs pairs
      | None -> default)
  | None -> (
      (* Try .irmin/config in repo *)
      let irmin_config = Filename.concat repo ".irmin/config" in
      match parse_config_file irmin_config with
      | Some pairs -> of_pairs pairs
      | None -> (
          (* Auto-detect from directory structure *)
          match detect_backend ~cwd:repo with
          | Some cfg -> cfg
          | None -> { default with store_path = repo }))
