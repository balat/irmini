(lang dune 3.21)
(name irmin)
(version 2.0.0~dev)

(generate_opam_files true)

(license ISC)
(authors "Thomas Gazagnaire <thomas@gazagnaire.org>")
(maintainers "Thomas Gazagnaire <thomas@gazagnaire.org>")

(source (tangled gazagnaire.org/irmin))

(package
 (name irmin)
 (synopsis "Content-addressable store with Git and ATProto MST support")
 (description
  "Irmin is a library for building content-addressable stores with lazy reads,
delayed writes, and multiple tree formats (Git, ATProto MST). It provides
bidirectional Git compatibility and first-class subtree operations.")
 (depends
  (ocaml (>= 5.2))
  (dune (>= 3.17))
  (eio (>= 1.2))
  (eio_main (>= 1.2))
  (digestif (>= 1.2))
  (fmt (>= 0.9))
  (logs (>= 0.7))
  (git (>= 0.1))
  (atp (>= 0.1))
  (alcotest :with-test)
  (crowbar :with-test)
  (qcheck-core :with-test)
  (qcheck-stm :with-test)
  (qcheck-stm-eio :with-test)
  (qcheck-multicoretests-util :with-test)
  (odoc :with-doc)))

(package
 (name irmin-lavyek)
 (synopsis "Lavyek backend for Irmin")
 (description
  "High-throughput persistent backend for Irmin using Lavyek, an LSM tree
with WAL, SST compaction, and page caching.")
 (depends
  (ocaml (>= 5.2))
  (irmin (= :version))
  (lavyek (>= 0.1))))
