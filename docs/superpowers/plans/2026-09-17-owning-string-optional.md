# Owning `String?` Implementation Plan (sub-project 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `String?` an owner in the C backend: `cell_opt_string_t`.
`Some(x)` moves `x`. `Some(owned s)`, `Some(shared s)`, `Some(_)` and `None`
bind or match it, and the value is released on every path that still holds
it.

**Architecture:** It reuses sub-projects 2 and 3.
- **Runtime:** add a predefined `cell_opt_string` optional.
- **typecheck and borrowck:** apply the owning-payload rules to `Some`.
- **codegen:**
  - map `String?` to `cell_opt_string`;
  - generate `cell_drop_opt_string` per module;
  - bind `.value`;
  - release a temporary optional in every arm that does not take it.
- **IR backends:** their `String?` spelling is reconciled to the owning
  32-byte struct in a separate step. That step runs after
  `feat/ir-string-conversions` merges, because the same files are in flight
  there.

**Spec:** `docs/superpowers/specs/2026-09-17-owning-string-err-and-optional-design.md` (sub-project 4; approved 2026-09-17: `String?` is owning).

## Global Constraints

These are the same as sub-projects 2 and 3, plus the following names:
- **Release glue:** `cell_drop_opt_string`.
- **Optional instance:** `cell_opt_string` (element `cell_string_t`, 32 bytes).
- **Old view spelling:** `cell_opt_str` stays in the header for hosts.

### Task 1: Runtime

- **Test first.** Add an assertion that `cell_opt_string_t` is 32 bytes and
  that a some/none pair behaves.
- **Implement.** Add `CELL_DEFINE_OPTIONAL(cell_opt_string, cell_string_t)`.
- **Verify, then commit.**

### Task 2: typecheck and borrowck

- **Tests first:**
  - `Some(s)` builds `String?`;
  - `Some(owned s)` and `Some(shared s)` are accepted;
  - a bare `Some(s)` on `String?` is refused;
  - `Some(owned v)` on `Int?` is refused as a scalar copy;
  - `Some(s)` moves `s`;
  - `Some(owned x)` consumes only on its own arm;
  - `Some(shared x)` borrows;
  - the "scalar payloads only" test becomes an acceptance test.
- **Implement.** Apply the owning rule to `.some` in both passes.
- **Verify, then commit.**

### Task 3: codegen

- **Tests first:**
  - `String?` lowers to `cell_opt_string_t`;
  - the glue is emitted once, with body `if (o->has_value) cell_string_free(&o->value);`;
  - `Some(owned x)` binds `.value` and is released at arm end;
  - `Some(shared x)` binds `cell_string_as_str(&t.value)`;
  - a temporary optional is released in the arms that do not take it;
  - reassignment releases the old value;
  - an unresolved `Some(x)` is copied.
- **Implement:**
  - map the optional instance;
  - admit it in `needsDrop`, `emitDropFor` and the reassignment path;
  - add glue collection for `String?`;
  - add binding, the "took" rule and the copy fallback for `.some`.
- **Verify** with the unit tests and the gate, then commit.

### Task 4: Example, fixture, refusal, docs, push

- **Example:** `examples/optional_string.cell`, C only, pinned, and run under
  ASan.
- **Leak fixture:** `examples/leaks/owned_string_optional.cell`, pinned at 0.
- **Falsify:** empty glue must leak; with no `Some(owned ..)` move, ASan must
  report a double free.
- **Refusal corpus:** `examples/rejected/owned_some_bare_binding.cell`.
- **Pin and README rows.** Add the fixture's pin and the matching README
  rows.
- **Docs:** SPEC 3.2 and 3.4, the 10.3 row, FEATURES TYPE-04 and PAT-02,
  OWNERSHIP, AGENTS, and the spec status.
- **Finish:** gate and gate integrity, commit, push.

### Task 5 (after the IR branch merges): the IR spelling of `String?`

- **Change:** `abi.optionalBase(String)` becomes `cell_opt_string`. The
  LLVM preamble gets `%cell_opt_string = type { i8, %cell_string }`, and
  MLIR's optional-of-String struct uses the owning String struct.
- **Constructors:** IR construction stays refused (`optionPayloadCarried`).
- **Tests:** pin the new spelling with a test.
- **Gate:** it must stay clean.
