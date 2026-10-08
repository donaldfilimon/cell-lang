# Zig master qualification: 2026-10-08

Donald selected `0.18.0-dev.120+9fe22a29b`. The package minimum, current README and gate version guard now name that exact snapshot. The official aarch64 macOS archive SHA256 is `b6225af37ce3700dae0326af70d44414bb7b85aaf846243122d945016077c60c`.

Using the versioned compiler, `LLVM_BIN=/opt/homebrew/opt/llvm/bin`, and scratch under `/private/tmp`, `sh tools/check.sh` exited 0 with verdict `clean` on native macOS ARM64. It executed 803 root tests and the complete corpus, backend verdict/output agreement, independent MLIR lowering, native execution, pinned leak controls, 66 ASan programs, declared-signature contracts, runtime/prelude, CLI and project-overlay checks. C++ remained enabled; Swift was disabled by the repository gate. No runtime/compiler source compatibility change was required.

Existing ownership expectations and unsupported-backend refusals remain intact. This qualifies the gate's maintained local configuration, not a Swift-enabled build, foreign-host execution, provider integration or every proposed language program. Historical verification records retain their original snapshots.
