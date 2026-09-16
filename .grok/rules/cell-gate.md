# Cell-lang Grok overlay

This repository is a Zig compiler. Do not use the bundled implementer bar (`fmt` / `clippy`).

- Every `zig build` and `zig build test` uses `-Dswift=false`.
- The repo gate is `tools/check.sh`. `zig build test` is not the language gate.
- `--test-filter` matching nothing still exits 0 because of the anonymous `refAllDecls` test in `src/root.zig`. Confirm the named test appears in the output.
- Unique work must land on canonical `main`, not only in a worktree.
