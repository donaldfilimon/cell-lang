# Cell capability and completion matrix

This is the current-status entry point. SPEC.md defines intended semantics;
OWNERSHIP.md defines ownership rules and retains historical defect evidence.
Their dated snapshot tables are not current qualification results.

Source inspected: compiler revision `584162a`, 2026-09-08. This matrix records
static source and fixture evidence, not freshly qualified execution. No row is
release-qualified on macOS, Linux or Windows. Gate reports qualify particular
revisions and cases, not every possible program using a feature.

`checked` means a frontend path exists; `lowered` means an emitter path exists;
`partial` means the row includes explicit restrictions or incomplete behavior;
`defect` means the backend accepts a known incorrect lowering or ABI shape;
`refused` means an intentional unsupported boundary; `absent` means no public
implementation. `reserved` is a keyword reservation, not a grammar promise.
`n/a` is an inapplicable layer. A partial backend row never promises every
operation on the named type. M1-M10 refer to the approved completion program.

| ID / capability | Frontend | C | LLVM | MLIR | Ownership / cleanup boundary | Evidence | Milestone |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LEX-01 ASCII names, spans, comments | checked | n/a | n/a | n/a | n/a | [lexer](../src/cell/lexer.zig) | M5 |
| LEX-02 decimal literals and strings | partial | partial | partial | partial | Escape interpretation incomplete | [primitives](../examples/primitives.cell), [lexer](../src/cell/lexer.zig) | M5 |
| LEX-03 radix/separator/exponent literals, Unicode names, advanced strings | absent | absent | absent | absent | n/a | [silent literals](../examples/rejected/silent_literals.cell) | M5 |
| TYPE-01 primitive types and aliases | checked | lowered | lowered | lowered | Primitive modes pass by value | [types](../src/cell/types.zig), [primitives](../examples/primitives.cell) | M5 |
| TYPE-02 unknown type rejection | absent | partial | refused | refused | Frontend can accept unresolved names | [unknown type](../examples/rejected/unknown_type.cell) | M2 |
| TYPE-03 structs and payload-free enums | checked | lowered | partial | partial | Aggregate destruction incomplete | [structs/enums](../examples/structs_enums.cell) | M4/M6 |
| TYPE-04 lists and optionals | partial | partial | partial | partial | Construction, ABI, indexing and cleanup differ | [primitives](../examples/primitives.cell), [exclusive aggregates](../examples/exclusive_aggregates.cell) | M4/M6 |
| TYPE-05 explicit unit type | absent | absent | absent | absent | Implicit function unit already exists | [unit type](../examples/future/unit_type.cell) | M5 |
| TYPE-06 generic types/functions and typed Result | absent | absent | absent | absent | Requires typed owning payloads | [generics](../examples/future/generics.cell), [Result](../examples/future/result.cell) | M6 |
| OWN-01 five ownership modes and owned default | checked | partial | partial | partial | Resource-bearing copy fields and non-fresh owned-field transfers are refused | [binding modes](../examples/let_binding_modes.cell), [owned field alias](../examples/rejected/owned_field_alias.cell) | M4 |
| OWN-02 move/borrow/alias checking | partial | n/a | n/a | n/a | Exact enforced clauses live in borrowck header | [borrow checker](../src/cell/borrowck.zig) | M2/M4 |
| OWN-03 named-loan NLL | partial | n/a | n/a | n/a | Slices 1/2 enforced; derived loans conservatively refused | [dead loan](../examples/nll_dead_borrow.cell), [aliasing](../examples/rejected/aliasing.cell) | M4 |
| OWN-04 ARC retain/release and transfer | partial | partial | partial | partial | C cleanup gaps; IR preserves return ownership and refuses nonprimitive ARC returns | [ARC](../examples/arc.cell), [ARC return signature](../examples/signatures/arc_string_return.cell) | M2/M4 |
| OWN-05 scope/aggregate/parameter destruction | partial | partial | absent | absent | Nonzero disclosed leak baselines remain | [leak contracts](../examples/leaks/README.md), [C emitter](../src/cell/codegen.zig) | M4 |
| FLOW-01 if/block/match values | checked | lowered | partial | partial | Owning branches constrained by move checker | [control flow](../examples/control_flow.cell) | M3/M4 |
| FLOW-02 while/break/continue | checked | lowered | lowered | lowered | Loop moves checked; broader cleanup incomplete | [loops](../examples/loops.cell) | M4/M5 |
| FLOW-03 for/loop/labels/defer | reserved | absent | absent | absent | Must share CFG cleanup | [parser](../src/cell/parser.zig), [lexer](../src/cell/lexer.zig) | M4/M5 |
| EXPR-01 named calls, fields, struct/list literals | checked | partial | partial | partial | Aggregate construction/moves remain restricted | [expressions](../examples/expressions.cell) | M3/M4 |
| EXPR-02 indexing, casts, remaining operators | absent | absent | absent | absent | Bounds/arithmetic contract required | [parser](../src/cell/parser.zig) | M5 |
| PAT-01 scalar/wildcard/binding/variant patterns and guards | partial | partial | partial | partial | Guarded binding patterns refused; arm consumption restricted | [patterns](../examples/pattern_matching.cell), [typecheck](../src/cell/typecheck.zig) | M6 |
| PAT-02 payload/destructuring/exhaustiveness | absent | absent | absent | absent | Requires ownership-aware pattern lowering | [enum payload](../examples/future/enum_payload.cell) | M6 |
| MOD-01 four extensions and stem pairing | checked | n/a | n/a | n/a | Same-directory pairing is a loader concern, not backend lowering | [geometry](../examples/pairing/geometry.cell), [body](../examples/pairing/geometry.body) | M7 |
| MOD-02 module resolution and visibility | partial | absent | absent | absent | use/pub parse without full import/visibility semantics | [loader](../src/cell/load.zig), [parser](../src/cell/parser.zig) | M7 |
| ABI-01 current C runtime and ARM64 classifier | partial | partial | partial | partial | Disclosed signature disagreements; no three-platform qualification | [runtime](../runtime/cell_rt.h), [classifier](../src/cell/abi.zig) | M7 |
| ABI-02 version 2, generated headers, other target ABIs | absent | absent | absent | absent | No compatibility claim for future typed payloads | [completion program](superpowers/plans/2026-09-08-full-language-completion.md) | M7 |
| CLI-01 check/dump/emit/version/help and caret diagnostics | checked | n/a | n/a | n/a | Parser stops at first error | [CLI](../src/main.zig), [diagnostics](../src/cell/diag.zig) | M9 |
| CLI-02 build/run/test and core SDK | absent | absent | absent | absent | Prelude contains declarations without runtime implementations | [prelude](../stdlib/prelude.cell) | M9 |
| ADV-01 traits/impl/methods | reserved | absent | absent | absent | Static generics plus explicit trait objects planned | [lexer](../src/cell/lexer.zig) | M6 |
| ADV-02 closures | absent | absent | absent | absent | No closure grammar, capture model or escaping-capture proof | [AST](../src/cell/ast.zig), [parser](../src/cell/parser.zig) | M8 |
| ADV-03 generators/async/unsafe | reserved | absent | absent | absent | `async`, `yield` and `unsafe` are reserved without grammar or semantics | [lexer](../src/cell/lexer.zig) | M8 |

## Future fixture ownership

All current `examples/future/*.cell` files remain rejection contracts until
their implementation lands: `generics.cell`, `result.cell`, `enum_payload.cell`
and `optional_list.cell` belong to M6; `unit_type.cell` belongs to M5.
[optional_list.cell](../examples/future/optional_list.cell) specifically records
optional-list type syntax rather than complete optional runtime semantics.

When a feature lands, update its row and move its future fixture into an
accepted contract with explicit execution/ownership expectations. Never change
a rejection expectation solely to silence the corpus gate. A release claim
requires the corresponding tests on all three backends and selected platforms.
