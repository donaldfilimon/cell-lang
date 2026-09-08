# Preserve return ownership through HIR

Parent: full-language completion milestones 2 and 3. This is a safety slice,
not completed ARC support or three-backend parity.

## Implementation

Add `ret_ownership: Ownership` to `hir.Fn`, lowering `Sig`, and HIR call
payloads. Extract from the declared AST return type alongside resolving its
value type: `.ref` supplies its ownership, otherwise `.owned`. Populate
metadata at signature collection, function lowering and call lowering; all
manual HIR constructors must state or deliberately default this field.

Both LLVM and MLIR must reject unsupported nonprimitive ARC return contracts
before choosing a value ABI. Cover bodyless declarations, definitions and
call-result lowering, including direct HIR input that contains a call without
the callee declaration. Diagnose `arc return type` at the original span.
Keep primitive ARC behavior consistent with the existing representation.
Do not change C ARC semantics or claim R11 parity. The current return ABI
classifier lacks an ownership argument; a checked refusal before it is the
safe interim boundary.

## Regression proof

HIR test `function and call retain declared return ownership`: check ownership
on a declaration, definition and call, including owned defaults and explicit
arc/shared/exclusive/copy annotations that the AST permits.

Each emitter: `arc return declarations definitions and calls are refused from
HIR ownership`. Exercise each path independently so declaration refusal cannot
hide missing call-result validation. Include ARC String, list and user struct;
preserve plain owning and primitive neighbors.

Update `examples/signatures/arc_string_return.cell` to describe the closed
unsafe signature via explicit refusal and remove only its two disclosure pins
after the gate demonstrates that both backends now refuse it intentionally.
Run full gate, record test counts and exits, and request independent review of
the complete task BASE..HEAD range.
