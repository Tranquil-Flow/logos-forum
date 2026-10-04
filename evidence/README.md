# Evidence layout

New evidence for this product lives here — one directory per attempt/slice:
`m0-build/`, `m1-transport/`, `m4-failure-matrix/`, etc.

Rules:
- Record exact commands, candidate hashes, topology, and byte-level readbacks.
- Keys, tokens and raw key-bearing logs stay OUT of this tree (private state
  root: `~/.local/share/lp0026-forum-dev/`).
- The predecessor proof tree is read-only; its sealed evidence is referenced,
  never re-labelled as this product's evidence.
- Synthetic technical test data is labelled `TECHNICAL TEST DATA` and kept
  separate from any real-usage forum state.
