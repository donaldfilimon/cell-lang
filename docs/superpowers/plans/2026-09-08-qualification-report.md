# Qualification report task

Parent: `2026-09-08-full-language-completion.md`, milestone 1.

## Contract

Add `tools/qualify.py`, a Python standard-library wrapper around the real
`tools/check.sh`. It streams the gate output, retains the log, and writes a
schema-versioned JSON report. Default artifacts belong in ignored
`.cell-cache/qualification/`; `--report PATH` selects a report destination.
`--strict` fails if any gate stage skips or a required stage does not run.
`--release` implies strict and also fails while disclosed ABI disagreements
or nonzero pinned leak baselines remain. Ordinary qualification must label
partial and disclosed outcomes explicitly, never call them release-ready.

Record actual source HEAD, branch, tracked/untracked dirty-state fingerprint,
platform, Zig/Clang/LLVM versions, gate exit, stage names and outcomes,
test counts actually observed (unknown counts are null), skips, failures,
disclosed defects, log path, and final verdict. Sample source identity before
and after the gate and fail on drift. Dirty input may be measured but cannot
be release-qualified. A report is evidence for the sampled source, never for
a later commit. Do not copy source diffs or private environment values into
reports. Ignore wrapper-generated artifacts when comparing source identity.

Missing tools, process-launch failure, signals, truncated stage output and
early build failure must still produce a failure report. Keep the underlying
gate unchanged in this task. No report should infer a CLI/runtime test count
from the library count. A missing Python runtime prevents this optional wrapper
from starting and must not change the shell gate's existing dependencies.

## Acceptance

Use isolated fake gate executions and temporary repositories for report tests:
complete clean, partial, disclosed defects, strict skips, release disclosures,
unexpected nonzero gate status, early build failure, source drift, dirty release,
signal, missing required stage, paths with spaces, and missing tool versions.
Test exit codes and serialized reports, not only parser helper return values.
Run the real gate once through the wrapper and inspect its JSON and preserved
log. Record exact count and stage evidence. No loosening of existing pins.

## Reviewed scope and artifact boundary

Validate artifact inode identity regardless of whether a path is inside the
checkout. Outside paths skip only Git pathname lookup, never tracked-source
or pairwise artifact hard-link checks. Regressions must preserve tracked bytes
for outside log and report-temporary aliases, and preserve aliased artifacts.

`qualification_scope` is `local_gate`. `local_gate_ready` requires a clean,
qualified local run. `release_ready` remains false until a separate evaluator
proves complete feature, same-SHA platform, ABI and extracted-artifact evidence.
`--release` applies stricter local checks; it cannot certify global readiness.
A synthetically clean local gate must still report global readiness false.
