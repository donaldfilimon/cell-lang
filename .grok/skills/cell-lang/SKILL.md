---
name: cell-lang
description: >
  Cell compiler (Zig) working rules for this repository: every zig build or
  test uses -Dswift=false, the repo gate is tools/check.sh, and --test-filter
  matching nothing still exits 0. Use when implementing, reviewing, building,
  testing, or finishing work in cell-lang, or when a generic bot would reach
  for fmt/clippy.
---

# Cell-lang Grok bots

This repo is a Zig compiler. The bundled implementer done-bar (`fmt` / `clippy`) does not apply.

## Gate

```sh
zig build -Dswift=false
zig build test -Dswift=false
tools/check.sh
```

`-Dswift=false` is mandatory on every `zig` build or test. The default enables a Swift bridge that hardcodes `/Applications/Xcode-beta.app` and fails elsewhere. The repo gate is `tools/check.sh`; its exit code is the verdict. `zig build test` prints nothing on success and does not run a single `.cell` program.

Capture exit codes from the command itself. Never `cmd | tail`. A failed `zig build` leaves the previous `zig-out/bin/cell` in place; check the build exit before invoking the binary.

## `--test-filter` false green

`zig test src/root.zig --test-filter "this-name-does-not-exist-anywhere"` exits 0 and prints `All 1 tests passed`. `src/root.zig` has an anonymous `test { refAllDecls(@This()); }` with no name for a filter to exclude, so it always runs. Confirm the named test appears in the output. The count is always one higher than the number of named tests that matched.

## Canonical checkout

Unique work must land on canonical `main` in this checkout. A worktree is unfinished until its work is merged back, the worktree directory is removed, and the branch label is deleted. Do not leave unique commits only in a worktree.

## Skill for running programs

For driving a `.cell` file through C/LLVM/MLIR, use the `run-cell-lang` skill and its driver.

## Computer control

Grok Bot's Agent Computer is the cloud desktop. It is not Claude Computer Use and not Orca. GUI clicks are not a substitute for `-Dswift=false` / `tools/check.sh`. See the `computer-control` skill.
