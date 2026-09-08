# List-element ownership admission follow-up

Milestone 2 follow-up to `2026-09-08-owned-field-alias.md`. This task is queued
for design review after the field safety boundary lands. It is not an
implementation or an assertion that list ownership is complete.

## Evidence and design boundary

The current list-literal ownership walk checks ARC uniqueness and unknown move
sources, then reads ordinary place elements. Binding metadata retains a struct
name but not the general declared type. A resource-shape decision cannot safely
infer that an identifier is scalar or that a call returns a fresh owning value
from syntax alone.

Introduce an expected-type-aware ownership walk. It owns recursion rather than
running a second walk after `checkExpr`, which would duplicate loans and moves.
Thread declared expectations from typed bindings, call parameters, return
contracts, assignment destinations, struct fields, and outer list elements.
Propagate a value expectation into if branches, match arm bodies, annotated
values, and trailing block expressions. Conditions, guards, scrutinees and
non-tail statements keep their own contexts.

For inferred destinations, retain compact structural type information on
bindings, populated from declared types, primitive/struct/list literals and
resolved call signatures. Resolve field projections through declared struct
fields. This is ownership resource classification, not a replacement general
typechecker. Unknown or recursive shapes must remain explicit unknowns.

At each element destination, reuse the structural resource classifier and the
field admission rule. Proven resource-free destinations retain scalar copying.
Resource-bearing destinations first reject borrowed or unresolved provenance,
then accept only proven fresh values. Unknown destination shape fails closed.
Do not mark sources moved while aggregate destruction and partial moves remain
unimplemented. Keep fresh-aggregate leak gaps individually disclosed.

## Acceptance axes

- Typed and inferred scalar lists and recursively scalar-only record lists
  accept existing place elements.
- String, nested list, optional resource and resource-bearing record elements
  reject unsafe place aliases, including field projections.
- Typed and inferred literals receive correct element expectations through
  binding, assignment, return, call argument and struct field destinations.
- Nested literals, if branches, match arms and block tails preserve destination
  shape without applying it to guards or conditions.
- Sigil/keyword borrows, borrowed parameters and borrowed call results cannot
  pass the fresh-value branch.
- Unknown/cyclic shapes fail closed with bounded diagnostics. Fresh scalar and
  fresh owning literal/call controls remain accepted where supported.

Before implementation, minimize runtime reproductions for currently accepted
resource aliases and independently review the exact propagation design. After
implementation, run named regressions and the complete compiler gate, retain
direct exit codes, and review the complete task commit range.
