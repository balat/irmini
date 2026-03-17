(** Runner for Irmin-Lwt cross-implementation tests.

    Build from the Irmin workspace (main branch):
      dune exec test-irmin-lwt/main.exe *)

let () = Alcotest.run "Irmin-Lwt" Test_irmin_lwt.suite
