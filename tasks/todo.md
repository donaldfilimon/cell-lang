# Todo

## Project Grok bots follow Cell's gate

- [x] Project `.grok/` overlays: implementer agent+persona, cell-lang skill, cell-gate rule
- [x] `tools/check-grok-bots.sh` fail-closed on `-Dswift=false`, `tools/check.sh`, `--test-filter`, `refAllDecls`, `worktree`
- [x] `tools/tests/test-grok-bots.sh` drives the real script
- [x] Gate stage 15; `grok inspect --json` project source, two runs identical
- [x] Overlay remaining spawnable agents (researcher, security-auditor, quick-search, design-doc-*)
- [x] Leave `abbey-assistant` user-scoped

## Next language residuals after a26f8b8

- [x] LEX-03: hex/bin/oct, digit separators, exponent floats; unterminated string diagnostic
- [x] EXPR-02: postfix `a[i]` for String and `[Byte]` (optional byte)
- [x] R16: field revival clears `moved_paths` for the revived path
- [x] HIR/LLVM/MLIR: untyped integer literals in Int8/UInt32 slots (`widths.cell` prints 16 on all three)
- [x] Gate `tools/check.sh` on `d3cf2ae`: clean, 592 tests

## Close residuals after the 2026-09-16 four-plan landing

- [x] Gate on `a26f8b8`: clean, 559 tests
