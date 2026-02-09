(** Irmin CLI - content-addressed storage. *)

open Cmdliner

(* === Logging setup via vlog === *)

let setup = Vlog.setup "irmin"

(* === Common arguments === *)

let repo =
  let doc = "Repository directory." in
  Arg.(value & opt string "." & info [ "r"; "repo" ] ~docv:"DIR" ~doc)

let branch =
  let doc = "Branch name." in
  Arg.(value & opt string "main" & info [ "b"; "branch" ] ~docv:"NAME" ~doc)

let output =
  let doc = "Output format: $(b,human) for terminal, $(b,json) for scripts." in
  Arg.(
    value
    & opt (enum [ ("human", `Human); ("json", `Json) ]) `Human
    & info [ "o"; "output" ] ~docv:"FORMAT" ~doc)

let message =
  let doc = "Commit message." in
  Arg.(
    value & opt (some string) None & info [ "m"; "message" ] ~docv:"MSG" ~doc)

(* === init === *)

let init_path =
  let doc = "Path for new repository." in
  Arg.(value & pos 0 string "." & info [] ~docv:"PATH" ~doc)

let init_backend =
  let doc =
    "Backend type: $(b,git) for Git-compatible, $(b,mst) for \
     ATProto-compatible."
  in
  Arg.(
    value
    & opt (enum [ ("git", `Git); ("mst", `Mst) ]) `Git
    & info [ "backend" ] ~docv:"TYPE" ~doc)

let init_cmd =
  let doc = "Initialise a new repository." in
  let man =
    [
      `S Manpage.s_examples;
      `Pre "  irmin init myrepo";
      `Pre "  irmin init --backend mst atproto-store";
    ]
  in
  Cmd.v
    (Cmd.info "init" ~doc ~man)
    Term.(
      const (fun () backend path -> Cmd_init.run ~backend path)
      $ setup $ init_backend $ init_path)

(* === get === *)

let get_path =
  let doc = "Path to read." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH" ~doc)

let get_cmd =
  let doc = "Read content at a path." in
  let man =
    [
      `S Manpage.s_examples;
      `Pre "  irmin get README.md";
      `Pre "  irmin get src/main.ml -b feature";
    ]
  in
  Cmd.v (Cmd.info "get" ~doc ~man)
    Term.(
      const (fun () repo branch output path ->
          exit (Cmd_get.run ~repo ~branch ~output path))
      $ setup $ repo $ branch $ output $ get_path)

(* === set === *)

let set_path =
  let doc = "Path to write." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH" ~doc)

let set_content =
  let doc = "Content to write. Reads from stdin if omitted." in
  Arg.(value & pos 1 (some string) None & info [] ~docv:"CONTENT" ~doc)

let set_cmd =
  let doc = "Write content at a path." in
  let man =
    [
      `S Manpage.s_examples;
      `Pre "  irmin set README.md '# Hello'";
      `Pre "  echo 'data' | irmin set config.txt";
      `Pre "  irmin set -m 'Add docs' README.md '# Project'";
    ]
  in
  Cmd.v (Cmd.info "set" ~doc ~man)
    Term.(
      const (fun () repo branch message path content ->
          Cmd_set.run ~repo ~branch ~message path content)
      $ setup $ repo $ branch $ message $ set_path $ set_content)

(* === del === *)

let del_path =
  let doc = "Path to delete." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH" ~doc)

let del_cmd =
  let doc = "Delete a path." in
  let man = [ `S Manpage.s_examples; `Pre "  irmin del old-file.txt" ] in
  Cmd.v (Cmd.info "del" ~doc ~man)
    Term.(
      const (fun () repo branch message path ->
          exit (Cmd_del.run ~repo ~branch ~message path))
      $ setup $ repo $ branch $ message $ del_path)

(* === list === *)

let list_prefix =
  let doc = "Path prefix to list." in
  Arg.(value & pos 0 (some string) None & info [] ~docv:"PREFIX" ~doc)

let list_cmd =
  let doc = "List paths." in
  let man =
    [ `S Manpage.s_examples; `Pre "  irmin list"; `Pre "  irmin list src/" ]
  in
  Cmd.v
    (Cmd.info "list" ~doc ~man)
    Term.(
      const (fun () repo branch output prefix ->
          exit (Cmd_list.run ~repo ~branch ~output prefix))
      $ setup $ repo $ branch $ output $ list_prefix)

(* === tree === *)

let tree_path =
  let doc = "Path to show tree from." in
  Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH" ~doc)

let tree_cmd =
  let doc = "Show tree structure." in
  let man =
    [ `S Manpage.s_examples; `Pre "  irmin tree"; `Pre "  irmin tree src/" ]
  in
  Cmd.v
    (Cmd.info "tree" ~doc ~man)
    Term.(
      const (fun () repo branch output path ->
          exit (Cmd_tree.run ~repo ~branch ~output path))
      $ setup $ repo $ branch $ output $ tree_path)

(* === log === *)

let log_limit =
  let doc = "Maximum commits to show." in
  Arg.(value & opt (some int) None & info [ "n" ] ~docv:"N" ~doc)

let log_cmd =
  let doc = "Show commit history." in
  let man =
    [
      `S Manpage.s_examples; `Pre "  irmin log"; `Pre "  irmin log -n 5 -o json";
    ]
  in
  Cmd.v (Cmd.info "log" ~doc ~man)
    Term.(
      const (fun () repo branch output limit ->
          exit (Cmd_log.run ~repo ~branch ~output ~limit ()))
      $ setup $ repo $ branch $ output $ log_limit)

(* === branches === *)

let branches_cmd =
  let doc = "List branches." in
  Cmd.v (Cmd.info "branches" ~doc)
    Term.(
      const (fun () repo output -> exit (Cmd_branches.run ~repo ~output ()))
      $ setup $ repo $ output)

(* === checkout === *)

let checkout_branch =
  let doc = "Branch to checkout or create." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"BRANCH" ~doc)

let create_flag =
  let doc = "Create a new branch." in
  Arg.(value & flag & info [ "c"; "create" ] ~doc)

let checkout_cmd =
  let doc = "Switch to a branch." in
  let man =
    [
      `S Manpage.s_examples;
      `Pre "  irmin checkout main";
      `Pre "  irmin checkout -c feature";
    ]
  in
  Cmd.v
    (Cmd.info "checkout" ~doc ~man)
    Term.(
      const (fun () repo create branch ->
          exit (Cmd_checkout.run ~repo ~create branch))
      $ setup $ repo $ create_flag $ checkout_branch)

(* === proof === *)

let proof_key =
  let doc = "Key to produce/verify proof for." in
  Arg.(required & opt (some string) None & info [ "k"; "key" ] ~docv:"KEY" ~doc)

let proof_data =
  let doc = "Data entries as KEY=VALUE." in
  Arg.(value & pos_all string [] & info [] ~docv:"KEY=VALUE" ~doc)

let proof_produce_cmd =
  let doc = "Produce a Merkle proof for a key." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Produces a Merkle proof for reading a key from an MST (Merkle Search\n\
        \        Tree). The proof contains only the data needed to verify the \
         read.";
      `S Manpage.s_examples;
      `Pre "  irmin proof produce -k mykey foo=bar baz=qux";
      `Pre "  irmin proof produce -k post/123 -o json 'post/123=Hello'";
    ]
  in
  Cmd.v
    (Cmd.info "produce" ~doc ~man)
    Term.(
      const (fun () output key data ->
          exit (Cmd_proof.produce ~output ~key data))
      $ setup $ output $ proof_key $ proof_data)

let proof_verify_cmd =
  let doc = "Verify a Merkle proof for a key." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Verifies that a Merkle proof correctly proves a read operation.\n\
        \        Returns exit code 0 if valid, 1 if invalid.";
      `S Manpage.s_examples;
      `Pre "  irmin proof verify -k mykey foo=bar baz=qux";
    ]
  in
  Cmd.v
    (Cmd.info "verify" ~doc ~man)
    Term.(
      const (fun () output key data ->
          exit (Cmd_proof.verify ~output ~key data))
      $ setup $ output $ proof_key $ proof_data)

let proof_cmd =
  let doc = "MST Merkle proofs (ATProto-compatible)." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Commands for working with Merkle proofs using the MST (Merkle Search\n\
        \        Tree) format, compatible with ATProto's repository sync \
         protocol.";
      `P "Proofs allow verifying tree operations without full data access.";
    ]
  in
  Cmd.group (Cmd.info "proof" ~doc ~man) [ proof_produce_cmd; proof_verify_cmd ]

(* === import === *)

let import_file =
  let doc = "File to import (CAR or plain content)." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"FILE" ~doc)

let import_cmd =
  let doc = "Import data from file." in
  let man =
    [
      `S Manpage.s_description;
      `P "Import data from external files. Format is auto-detected:";
      `I ("$(b,.car)", "CAR file (ATProto blocks)");
      `I ("$(b,other)", "Plain content added at path");
      `S Manpage.s_examples;
      `Pre "  irmin import repo.car";
      `Pre "  irmin import data.json";
    ]
  in
  Cmd.v
    (Cmd.info "import" ~doc ~man)
    Term.(
      const (fun () repo branch file ->
          exit (Cmd_import.run ~repo ~branch file))
      $ setup $ repo $ branch $ import_file)

(* === export === *)

let export_output =
  let doc = "Output file path." in
  Arg.(
    required & opt (some string) None & info [ "o"; "output" ] ~docv:"FILE" ~doc)

let export_cmd =
  let doc = "Export store to file." in
  let man =
    [
      `S Manpage.s_description;
      `P "Export store contents. Format determined by extension:";
      `I ("$(b,.car)", "CAR file (ATProto format)");
      `S Manpage.s_examples;
      `Pre "  irmin export -o backup.car";
    ]
  in
  Cmd.v
    (Cmd.info "export" ~doc ~man)
    Term.(
      const (fun () repo branch output ->
          exit (Cmd_export.run ~repo ~branch ~output ()))
      $ setup $ repo $ branch $ export_output)

(* === info === *)

let info_file =
  let doc = "File to inspect (optional, defaults to store info)." in
  Arg.(value & pos 0 (some string) None & info [] ~docv:"FILE" ~doc)

let info_cmd =
  let doc = "Show store or file information." in
  let man =
    [
      `S Manpage.s_description;
      `P "Display information about the store or a specific file.";
      `S Manpage.s_examples;
      `Pre "  irmin info";
      `Pre "  irmin info repo.car";
    ]
  in
  Cmd.v
    (Cmd.info "info" ~doc ~man)
    Term.(
      const (fun () repo file -> exit (Cmd_info.run ~repo file))
      $ setup $ repo $ info_file)

(* === Main === *)

let main_cmd =
  let doc = "Content-addressed storage" in
  let man =
    [
      `S Manpage.s_description;
      `P "Irmin is a content-addressed store with Git-like semantics.";
      `P "Configuration is auto-detected from the repository:";
      `I ("$(b,.git/)", "Git backend (SHA-1, Git-compatible)");
      `I ("$(b,.irmin/config)", "Custom backend configuration");
      `S Manpage.s_see_also;
      `P "$(b,git)(1)";
    ]
  in
  let info = Cmd.info "irmin" ~version:Mono_info.version ~doc ~man in
  Cmd.group info
    [
      init_cmd;
      get_cmd;
      set_cmd;
      del_cmd;
      list_cmd;
      tree_cmd;
      log_cmd;
      branches_cmd;
      checkout_cmd;
      import_cmd;
      export_cmd;
      info_cmd;
      proof_cmd;
    ]

let () = exit (Cmd.eval main_cmd)
