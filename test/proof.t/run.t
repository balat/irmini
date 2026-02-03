MST Merkle Proofs - ATProto-compatible sparse proofs

Merkle proofs allow verifying tree operations without full data access.
This demonstrates Irmin's MST (Merkle Search Tree) proof format, compatible
with ATProto's repository sync protocol.

  $ ../mst_proof.exe | sed 's/[a-f0-9]\{16,64\}/HASH/g'
  MST Root: HASH
  
  Proof for: post/3k2yihx
  Value: Hello World
  
  Before: HASH (read-only, no change)
  After:  HASH
  
  Verifying proof (no backend access)...
  ✓ Verified: Hello World



