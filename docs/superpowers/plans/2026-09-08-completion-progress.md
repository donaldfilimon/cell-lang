# Cell completion execution ledger

Plan: `2026-09-08-full-language-completion.md`
Baseline: `584162a`; user approved implementation 2026-09-08.

## Preflight

| Interface or task | Check | Ruling |
| --- | --- | --- |
| Gate and compiler fixes | New validation may expose existing source defects | Keep new failures visible; do not add exception pins to make progress appear green |
| Shared IR and new language features | New captures/references invalidate the AST-only lifetime proof | Complete shared loan/cleanup representation before escape or suspension features |
| Platform qualification | Only local macOS has been inspected | Hosted results must be obtained separately before release claims |
| Canonical main and generic SDD worktree default | Repository explicitly requires canonical main | Use canonical main and serialize shared writers |
| Gate integrity task | Count failure, emitter failure, signature lowering | One bounded tools task followed by independent review |

## Milestone status

All ten milestones are incomplete. No fresh full-gate result was established
by planning. Task reports below will record actual commits and validation.

## Task evidence

- Gate integrity: complete, `b603be4..9805d71`, follow-up `9805d71..02d4f0f`.
  Independent review initially found unclassified LLVM failure in stage 10 and
  insufficient control-flow coverage. Both were fixed and scoped re-review
  approved. Targeted harness and shell syntax passed. Full gate log reported
  414 tests, 14 answer-comparison programs, 14 ASan programs, 203 signatures
  across 24 examples, four disclosed disagreements, and a clean verdict.
  The shell wrapper lost the direct exit code by assigning zsh's reserved
  `status` variable; do not claim preserved exit-code evidence for that run.
- Gate review minor, deferred: `SIG_COVERAGE_FAILURE` duplicates state already
  enforced by concrete failing branches. No correctness issue found.
- Capability matrix: `02d4f0f..e03026e`, corrected in `e03026e..fccea17`.
  Independent re-review approved the scoped documentation changes. Forty-five
  evidence links resolve. Matrix explicitly records static, unqualified status.
- Qualification wrapper: initial implementation `fccea17..0b7fc80`. A real run
  at clean `0b7fc80c1a0ba37ff140219891af0efe908cf0f5` preserved wrapper exit 0
  and gate exit 0: 414 library tests, all ten stages, no skips or source drift.
  Its verdict is `disclosed`, with four nonzero leak fixtures and four ABI
  disagreements; `release_ready` is false. CLI/runtime counts remain unknown.
  Original report and log are retained under `docs/qualification/2026-09-08-0b7fc80/`.
  Independent review requires artifact-path collision/source protection,
  correct dirty deletion/rename sampling, and an exit-zero truncation test.
  Review fixes landed in `3e50928` and `337fd01`; independent re-review is
  found an outside-root inode-check bypass. Follow-up `e4c41e5..282e75a`
  closes it and explicitly limits reports to local gate qualification.
  Independent review approved; 19 integration tests pass and outside-path
  negative controls fail against the old implementation. Evidence is under
  `docs/qualification/2026-09-08-282e75a/`.
  The recorded real run is not evidence for these later commits.
- Confirmed current defect: an owning String place copied into a struct field
  and consumed by a freeing C host produces an ASan double free (SIGABRT).
  The minimized reproduction passed checking and emission at compiler 584162a.
  Safety task contract: `2026-09-08-owned-field-alias.md`.
- Ruling: the agent thread limit prevented fresh implementer creation. Reuse
  the task implementer with bounded briefs and retain independent read-only
  reviewers; parent authored the documentation matrix for independent review.
  Cost if wrong: less context isolation, mitigated by exact diff reviews.

- Owning struct-field safety: implementation `337fd01..6b6a8ee`, independent
  specification review approved with a non-blocking request for scalar and
  scalar-record initializer controls. Quality review found a remaining
  nonprimitive ARC-field classification gap: a boxed scalar-only record
  inside an outer copy field can still be shallow-copied. Follow-up is queued.
  Primitive ARC remains by-value and is not that defect.
  Implementer reports direct
  full-gate exit 0, 419 library tests, 151 borrow-checker tests, and rejection
  of the retained double-free reproduction before emission. Resource-bearing
  copy fields reject at declaration; owning resource fields require fresh
  values. General copy bindings and list elements remain separate gaps.
- Contract completeness: `927fa93` records missing independently testable
  acceptance rows and the distinction between local and global release
  qualification. These obligations remain open.

- Nested ARC-field classification gap CLOSED. The classifier now carries the
  written ownership keyword into recursion at three places: field annotations,
  the qualified `.ref` spelling, and struct-field recursion. Each of the three
  was fault-injected separately and each is caught by the new named test
  `a boxed record hides in a copy field until the classifier reads field
  ownership` (425 tests, was 424). Measured rather than assumed: `arc Point`
  emits `cell_arc_t point;` and `arc Int` emits `int64_t n;`, so the boundary
  mirrors codegen's `applyOwnership` primitive check instead of rejecting every
  ARC annotation. Controls that must keep passing and do: primitive ARC nested
  in a copy field, `arc` over an enum, `copy n: arc Int`, and scalar-only
  record copy fields. Still outstanding and unchanged: general copy bindings,
  list elements, and complete structural copyability.

## Active task

Return ownership metadata in `2026-09-08-return-ownership.md`, starting at
`6b6a8ee`. Independent owning-field and qualification-wrapper reviews run
alongside that disjoint implementation. All ten milestones remain incomplete;
completed gate subtasks do not imply completed language semantics.
