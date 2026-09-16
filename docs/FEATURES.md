# Cell capability and completion matrix

This is the current-status entry point. SPEC.md defines intended semantics;
OWNERSHIP.md defines ownership rules and retains historical defect evidence.
Their dated snapshot tables are not current qualification results.

Source inspected: compiler revision `d3cf2ae`, 2026-09-16. This matrix records
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
| LEX-02 decimal literals and strings | checked | lowered | lowered | lowered | Parser decodes `\n \t \r \\ \" \0`; no `\u{...}`, raw, interpolated, or multi-line (LEX-03) | [escapes](../examples/escapes.cell), [primitives](../examples/primitives.cell), [parser](../src/cell/parser.zig) | M5 |
| LEX-03 radix/separator/exponent literals, Unicode names, advanced strings | partial | partial | partial | partial | Hex/bin/oct, underscores, exponent floats, and unterminated-string diagnostic landed. No Unicode names, no `\u{...}`, raw, interpolated, multi-line, or hexadecimal floats | [silent literals](../examples/silent_literals.cell), [hex float](../examples/rejected/hex_float.cell), [lexer](../src/cell/lexer.zig) | M5 |
| TYPE-01 primitive types and aliases | checked | lowered | lowered | lowered | Primitive modes pass by value. `Int8`/`Int16`/`UInt8`/`UInt16`/`UInt32` are distinct tags; `UInt8` is not `Byte`; `Char` stays unknown | [types](../src/cell/types.zig), [primitives](../examples/primitives.cell), [widths](../examples/widths.cell) | M5 |
| TYPE-02 unknown type rejection | checked | partial | refused | refused | Unresolved names refused at typecheck (`unknown type 'Strng'`). C codegen still maps an unchecked name to `void*` | [unknown type](../examples/rejected/unknown_type.cell) | M2 |
| TYPE-03 structs and payload-free enums | checked | lowered | partial | partial | Aggregate destruction incomplete | [structs/enums](../examples/structs_enums.cell) | M4/M6 |
| TYPE-04 lists and optionals | checked | partial | partial | partial | Scalar `T?` constructs and matches in C (`Some`/`None`); LLVM/MLIR refuse those constructors. `[Byte][i]` indexes as `Byte?`; `[Int]` and other element types still have no indexing | [optionals](../examples/optionals.cell), [index](../examples/index.cell), [primitives](../examples/primitives.cell) | M4/M6 |
| TYPE-05 explicit unit type | checked | lowered | lowered | lowered | `()` is a return type only; a `let`/parameter/field of unit is refused | [unit type](../examples/unit_type.cell) | M5 |
| TYPE-06 generic types/functions and typed Result | checked | partial | refused | refused | Scalar `Result<T, E>` constructs and matches in C (`Ok`/`Err`); `E` is Int32 or a payload-free enum. Other generics refused at parse. No drop (an owned Result leaks) | [results](../examples/results.cell), [generics](../examples/future/generics.cell) | M6 |
| OWN-01 five ownership modes and owned default | checked | partial | partial | partial | Resource-bearing copy fields and non-fresh owned-field transfers are refused | [binding modes](../examples/let_binding_modes.cell), [owned field alias](../examples/rejected/owned_field_alias.cell) | M4 |
| OWN-02 move/borrow/alias checking | partial | n/a | n/a | n/a | Exact enforced clauses live in borrowck header | [borrow checker](../src/cell/borrowck.zig) | M2/M4 |
| OWN-03 named-loan NLL | partial | n/a | n/a | n/a | Slices 1/2 enforced; derived loans conservatively refused | [dead loan](../examples/nll_dead_borrow.cell), [aliasing](../examples/rejected/aliasing.cell) | M4 |
| OWN-04 ARC retain/release and transfer | partial | partial | partial | partial | C cleanup gaps; IR preserves return ownership and refuses nonprimitive ARC returns | [ARC](../examples/arc.cell), [ARC return signature](../examples/signatures/arc_string_return.cell) | M2/M4 |
| OWN-05 scope/aggregate/parameter destruction | partial | partial | absent | absent | Nonzero disclosed leak baselines remain | [leak contracts](../examples/leaks/README.md), [C emitter](../src/cell/codegen.zig) | M4 |
| FLOW-01 if/block/match values | checked | lowered | partial | partial | Owning branches constrained by move checker | [control flow](../examples/control_flow.cell) | M3/M4 |
| FLOW-02 while/break/continue | checked | lowered | lowered | lowered | Loop moves checked; broader cleanup incomplete | [loops](../examples/loops.cell) | M4/M5 |
| FLOW-03 for/loop/labels/defer | reserved | absent | absent | absent | Must share CFG cleanup | [parser](../src/cell/parser.zig), [lexer](../src/cell/lexer.zig) | M4/M5 |
| EXPR-01 named calls, fields, struct/list literals | checked | partial | partial | partial | Aggregate construction/moves remain restricted | [expressions](../examples/expressions.cell) | M3/M4 |
| EXPR-02 indexing, casts, remaining operators | partial | partial | refused | refused | `a[i]` for `String` and `[Byte]` as `Byte?` (OOB is None). C calls the runtime helpers; LLVM/MLIR refuse together. Casts and remaining operators still absent. Indexed assignment refused | [index](../examples/index.cell), [parser](../src/cell/parser.zig) | M5 |
| PAT-01 scalar/wildcard/binding/variant patterns and guards | partial | partial | partial | partial | Guarded binding patterns refused; arm consumption restricted | [patterns](../examples/pattern_matching.cell), [typecheck](../src/cell/typecheck.zig) | M6 |
| PAT-02 payload/destructuring/exhaustiveness | partial | partial | refused | refused | Wrap patterns `Some`/`None`/`Ok`/`Err` bind a scalar payload in C; nested patterns and enum payloads remain absent; LLVM/MLIR refuse wrap patterns | [optionals](../examples/optionals.cell), [results](../examples/results.cell), [enum payload](../examples/future/enum_payload.cell) | M6 |
| MOD-01 four extensions and stem pairing | checked | n/a | n/a | n/a | Same-directory pairing is a loader concern, not backend lowering | [geometry](../examples/pairing/geometry.cell), [body](../examples/pairing/geometry.body) | M7 |
| MOD-02 module resolution and visibility | partial | absent | absent | absent | use/pub parse without full import/visibility semantics | [loader](../src/cell/load.zig), [parser](../src/cell/parser.zig) | M7 |
| ABI-01 current C runtime and ARM64 classifier | partial | partial | partial | partial | Disclosed signature disagreements; no three-platform qualification | [runtime](../runtime/cell_rt.h), [classifier](../src/cell/abi.zig) | M7 |
| ABI-02 version 2, generated headers, other target ABIs | absent | absent | absent | absent | No compatibility claim for future typed payloads | [completion program](superpowers/plans/2026-09-08-full-language-completion.md) | M7 |
| CLI-01 check/dump/emit/version/help and caret diagnostics | checked | n/a | n/a | n/a | Parser stops at first error | [CLI](../src/main.zig), [diagnostics](../src/cell/diag.zig) | M9 |
| CLI-02 build/run/test and core SDK | checked | partial | refused | refused | `cell build`/`cell run`/`cell test` landed 2026-09-16 (C target only). Prelude group 3 links; `cell test tests/` is gate stage 14 | [CLI](../src/main.zig), [gate stages 13-14](../tools/check.sh), [prelude](../stdlib/prelude.cell), [tests](../tests/README.md) | M9 |
| ADV-01 traits/impl/methods | reserved | absent | absent | absent | Static generics plus explicit trait objects planned | [lexer](../src/cell/lexer.zig) | M6 |
| ADV-02 closures | absent | absent | absent | absent | No closure grammar, capture model or escaping-capture proof | [AST](../src/cell/ast.zig), [parser](../src/cell/parser.zig) | M8 |
| ADV-03 generators/async/unsafe | reserved | absent | absent | absent | `async`, `yield` and `unsafe` are reserved without grammar or semantics | [lexer](../src/cell/lexer.zig) | M8 |

## Future fixture ownership

All current `examples/future/*.cell` files remain rejection contracts.
`generics.cell`, `enum_payload.cell` and `optional_list.cell` wait on their
features and belong to M6. `result.cell` stays in `future/` because it
`return`s a `String` where `Result<String, Int>` is declared, not because
construction is missing: `Ok`/`Err` exist and
[results.cell](../examples/results.cell) is the accepted contract.
[optional_list.cell](../examples/future/optional_list.cell) specifically
records optional-list type syntax rather than complete optional runtime
semantics. `()` in type position landed as TYPE-05;
[unit_type.cell](../examples/unit_type.cell) is the accepted contract.

When a feature lands, update its row and move its future fixture into an
accepted contract with explicit execution/ownership expectations. Never change
a rejection expectation solely to silence the corpus gate. A release claim
requires the corresponding tests on all three backends and selected platforms.
