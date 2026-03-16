let () =
  Alcotest.run "Irmin"
    [
      Test_hash.suite;
      Test_tree.suite;
      Test_backend.suite;
      Test_store.suite;
      Test_codec.suite;
      Test_link.suite;
      Test_proof.suite;
      Test_commit.suite;
      Test_git_interop.suite;
      Test_subtree.suite;
      Test_lru.suite;
    ]
