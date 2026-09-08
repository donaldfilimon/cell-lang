# Reject unsafe aliases entering owning struct fields

Milestone 2 safety slice. This closes struct-field alias creation; list-element
type propagation and complete aggregate transfers/destruction are separate work.

## Confirmed defect

At compiler revision 584162a, `make() -> String { return "ab" }`, followed by
`let owned s1 = make(); let owned t: Tag = Tag { name: s1 }; take(owned t.name)`
passes checking and C compilation. A C host implementing `take` by freeing its
owned String produces an AddressSanitizer double free, process SIGABRT (-6).
Tag declares `owned name: String`. Both the field and original local hold one
buffer; the checker reads the initializer and the original local still drops.

## Bounded implementation

In borrowck, introduce a total recursive resource-shape classifier over declared
AST types: primitive numeric/Bool/Byte/unit and known enums have no resources;
String and lists have resources; optional/Result inherit payload resource
properties; structs recursively combine all field shapes. Unknown names and
unproved recursive cycles return unknown. Ownership keywords cannot make a
resource header trivially copyable. Use existing type definitions rather than
guessing from expression spelling.

At the existing declared-owned struct-field initializer choke point, keep the
R10 check. A no-resource destination retains existing checking, including
scalar identifiers and scalar-only record identifiers. Unknown destination
shape fails closed. For a resource destination, first use the total borrowSource
classifier and reject borrow/unresolved results. Then use ownedMoveSource and
allow only a fresh no_owned_place result; reject places, aliasing arm places and
unknowns. This order matters: ownedMoveSource calls sigil borrows no_owned_place,
relying on checks that previously did not run at fields.

Keep existing scalar-return and fresh owning-call controls valid. Do not mark
sources moved without implementing aggregate drop/partial-move state. Do not
claim this implements transfers: diagnostic must explain this is an unsupported
transfer into an owning aggregate and identify source and destination.

## Tests and boundaries

Add named tests and a rejected corpus fixture for the confirmed String case;
cover field-path and annotated place sources, nested resource-bearing structs,
list-typed fields, optional resource fields, borrowed sigil/keyword/call sources,
and unknown/cyclic destination types. Exercise all enum variants of both total
classifiers. Preserve scalar field identifiers, scalar-only record identifiers,
fresh String literal/call fields and existing accepted corpus contracts.

Recheck the exact retained ASan reproduction: it must now fail cell check before
emission. Run named regressions and full tools/check.sh with direct captured
exit and actual test count. Update current false 'not a double free today'
comments in the changed code and ownership rule discussion, explicitly leaving
list elements and fresh-aggregate cleanup outstanding. Request independent
review of the complete task commit range before marking the slice complete.
