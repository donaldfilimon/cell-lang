# Early `return` ends its path in borrowck: plan

Date: 2026-09-17. Approved by Donald the same day ("Both, A then B").
Scope: borrowck `checkIf` only. `match` arms were the follow-up and landed
the same day as design C (same rule in `checkMatch`, plus a trailing
`match` whose arms all diverge).

## Problem

`checkIf` unions the then-branch's `dead` set into the state after the `if`
even when that branch always leaves by `return`, `break` or `continue`. These
two programs are refused today (`use of 's' after it was moved`):

```cell
pub fn early(copy c: Bool, owned s: String) {
    if c {
        take(s)
        return
    }
    take(s)
}
pub fn early_value(copy c: Bool, owned s: String) -> String {
    if c {
        return s
    }
    return s
}
```

## Design

1. A syntax-level helper `branchDiverges(expr)`: true for a block whose last
   statement is `return`, `break` or `continue`, or whose last statement is an
   `if` with an `else` where both branches diverge, or a nested block that
   diverges. Anything it cannot prove returns false, which keeps today's
   refusal.
2. In `checkIf`, a diverging branch contributes nothing to the merge:
   - then diverges, else does not: the state after is the else path's state;
   - else diverges, then does not: the state after is the then path's state;
   - both diverge: the code after is unreachable, and the state after is the
     entry state.
3. Nothing is lost: a `break` already saved its state (`saveBreakState`), a
   `continue` was already checked by R2.a (`checkContinue`), and a `return`
   leaves the function.
4. `branch_end` records are unchanged. Codegen emits no release at the end of
   a diverging branch (`endsInJump`), and the releases after the `if` now read
   a live record where the value really is live.

## Verification

1. RED first: borrowck tests for `early` and `early_value` fail before the
   change.
2. Borrowck tests: both programs accepted. Still refused: a branch that only
   sometimes returns, an `if` without `else` as the diverging tail, and a use
   after a nested `if` where only one branch returns.
3. Break and continue: a moved-then-`break` branch followed by a use inside
   the loop is accepted, and the use after the loop is still refused.
4. `examples/early_return.cell` with an `EXPECT-OUTPUT` line, run on all three
   backends. The C side runs under ASan in the gate's sanitizer stage.
5. `examples/leaks/early_return.cell` loops both shapes and is pinned at 0
   on both witnesses.
6. Full `tools/check.sh`, verdict `clean`. Update FEATURES, the
   OWNERSHIP/SPEC wording on the conservative merge, and the ledger.
