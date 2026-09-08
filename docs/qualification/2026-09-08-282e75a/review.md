# Qualification wrapper final review

Scope: working diff against `e4c41e5`, limited to `tools/qualify.py`,
`tools/tests/test_qualify.py`, and
`docs/superpowers/plans/2026-09-08-qualification-report.md`.

## Verdict

Approved. I found no actionable correctness, specification-compliance, or
quality defect in the scoped follow-up.

## Artifact containment

`validate_artifact_paths` now uses checkout containment only to decide whether
to run the Git pathname query (`tools/qualify.py:77-90`). It no longer skips the
subsequent filesystem inspection for an outside path. Every existing regular
artifact is compared by `(st_dev, st_ino)` both against all existing tracked
regular files and against the other artifacts (`tools/qualify.py:91-104`). This
closes the outside-root hardlink bypass for the report, log, and report
temporary while retaining the direct tracked-path and resolved-path collision
checks.

The regression at `tools/tests/test_qualify.py:243-268` exercises the requested
outside log alias, outside report-temporary alias, and pairwise outside alias.
It asserts exit 2, the hardlink diagnostic, preservation of tracked bytes, and
preservation of the pre-existing artifact in the pairwise case. The direct
inside-root tracked and hardlink cases remain covered at lines 207-241. The
three artifacts traverse the same loop, so a separate outside report hardlink
case would duplicate the same branch rather than cover a distinct interface.

## Qualification scope

The report now states `qualification_scope: local_gate`, derives
`local_gate_ready` only from a qualified verdict and clean sampled input, and
sets `release_ready` unconditionally false (`tools/qualify.py:361-367`). Thus a
skip, disclosure, gate error, source-sampling error, source drift, or dirty
input cannot produce local readiness. `--release` continues to impose strict
skip, disclosure, and clean-input checks at lines 327-333, but its successful
exit represents satisfaction of those local checks rather than global release
certification.

The clean synthetic release test asserts the local/global distinction and the
reason text (`tools/tests/test_qualify.py:105-111`). The plan's reviewed-scope
section accurately documents that the future evaluator must establish feature,
same-SHA platform, ABI, and extracted-artifact evidence before global release
readiness can change.

## Quality and verification assessment

The change is small and follows the existing error boundary: validation occurs
before either artifact is opened, and validation failures remain argparse-style
exit 2 failures. `git diff --check` is clean for the scoped files. I relied on
the reported 19 passing integration tests and did not rerun the compiler gate,
as requested. The reported old-code negative control is the appropriate
independent proof that the added regression detects the original bypass.

Residual limitation: this is a local, non-adversarial evidence wrapper, so the
usual filesystem time-of-check/time-of-use race remains between validation and
opening an artifact. The task did not require hostile concurrent filesystem
mutation, and this does not weaken the tested accidental-hardlink safety
contract.
