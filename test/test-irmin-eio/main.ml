(** Runner for Irmin-Eio cross-implementation tests.

    Build from the Irmin workspace (cuihtlauac-inline-small-objects-v2 branch):
      dune exec test-irmin-eio/main.exe *)

let () = Alcotest.run "Irmin-Eio" Test_irmin_eio.suite
