# Owning-field alias fix: specification and safety review

Reviewed range: `337fd016ee6025863539391d4643607e336d4224..6b6a8ee`

Verdict: **approve with a non-blocking regression-coverage limitation**.

## Safety and specification findings

No actionable safety defect was found in the scoped implementation.

The destination classifier is total over every `ast.TypeExpr` variant. `String`
and lists are resource-bearing; optional, result, and ownership-qualified types
recurse; known primitives and enums are resource-free; structs recursively
combine field shapes; unresolved names and recursive cycles return `unknown`.
The recursion guard fails closed. The implementation does not infer resource
ownership from initializer syntax.

The owned-field guard preserves the required ordering. R10's arc-to-owned check
runs first. A resource-bearing destination then asks the total `borrowSource`
classifier before `ownedMoveSource`, so sigil borrows, ownership-keyword borrows,
borrowed direct-call results, and propagated borrow results cannot use
`OwnedMove.no_owned_place` as an escape. For a non-borrowing source, only a fresh
`no_owned_place` value is admitted; places, match aliases, and unresolved value
shapes are refused. Unknown destination resource shape is refused independently
of source shape.

The match-alias path is covered both structurally and by the updated R7 test.
Field-path place sources, annotated place sources, direct fresh calls, literals,
nested resource-bearing structs, optional resource fields, list-typed fields,
unknown destinations, and cyclic destinations have named coverage.

The declaration guard for `copy` fields is placed after the existing
shared/exclusive lifetime rejection and uses the same recursive resource
classifier. It rejects resource-bearing and unknown shapes, including nested
structs and optional wrappers, while preserving known scalar and recursively
scalar-only declarations. ARC fields remain outside this copy-field refusal, as
required by the approved boundary.

The implementation correctly refuses alias admission rather than calling
`movePlace`; it therefore does not claim aggregate transfer, partial-move state,
or recursive record destruction. Documentation and the rejected corpus fixture
state that limit accurately, and list-element transfer remains explicitly open.

## Non-blocking coverage limitation

The approved plan explicitly requires preservation of both a scalar identifier
used as an owned field initializer and a scalar-only record identifier used as
an owned field initializer. The new tests prove the classifier returns
`no_resources` for these declarations, but they do not directly run these two
initializer forms through the owned-field guard. The implementation preserves
them by inspection: the `.no_resources` branch permits `.place`. Still, add
focused accepted controls in the next borrow-checker test update:

```cell
pub struct Point { copy x: Int }
pub struct ScalarBox { owned value: Int }
pub struct PointBox { owned value: Point }

pub fn f(copy n: Int, copy p: Point) {
    let owned a = ScalarBox { value: n }
    let owned b = PointBox { value: p }
}
```

This is a test-completeness issue, not a release-blocking defect in the reviewed
implementation. The reported full-gate result of 419 tests was not rerun during
this read-only review.

## Approval limits

This approval covers only unsafe aliases entering resource-bearing owned struct
fields and the scoped `copy` field declaration guard. It does not approve list
element ownership transfer, general copyability, aggregate destruction,
path-sensitive partial moves, fresh aggregate cleanup, or complete ownership.
