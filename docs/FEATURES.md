# Cell capability and completion matrix

This is the current-status entry point. SPEC.md defines intended semantics;
OWNERSHIP.md defines ownership rules and retains historical defect evidence.
Their dated snapshot tables are not current qualification results.

Source inspected: compiler revision `59a42b7`, 2026-09-17. This matrix records
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
| TYPE-04 lists and optionals | checked | partial | partial | partial | Scalar `T?` constructs and matches (`Some`/`None`) in all three backends and `optionals.cell` prints the same answer on each; LLVM/MLIR refuse `Float32?`, `String?`, and a constructor with no declared optional destination. `[Byte][i]` indexes as `Byte?`, and `[Int]`/`[Int32]`/`[Float]`/`[Bool]` as their element's optional in C since 2026-09-17; `[String]` and owning elements have no indexing | [optionals](../examples/optionals.cell), [index](../examples/index.cell), [primitives](../examples/primitives.cell) | M4/M6 |
| TYPE-05 explicit unit type | checked | lowered | lowered | lowered | `()` is a return type only; a `let`/parameter/field of unit is refused | [unit type](../examples/unit_type.cell) | M5 |
| TYPE-06 generic types/functions and typed Result | checked | partial | partial | partial | Scalar `Result<T, E>` constructs and matches (`Ok`/`Err`) in all three backends and `results.cell` prints the same answer on each; `E` is any scalar primitive or a payload-free enum, carried at its own width in a per-pair struct (`cell_res_<ok>_<err>_t`, ABI 2, 2026-09-17); [results_wide](../examples/results_wide.cell) pins a 64-bit error on all three backends, and [results_small](../examples/results_small.cell) runs 8- and 2-byte Results across calls in one word. An owning `String` `Ok` is built, matched (`Ok(owned s)`/`Ok(shared s)`/`Ok(_)`) and released in C since 2026-09-17 ([results_string](../examples/results_string.cell), leak fixture pinned at 0). LLVM/MLIR refuse a non-scalar side and an `Ok`/`Err` with no declared Result destination (typed let, parameter, return). Other generics refused at parse. No drop glue, and none needed yet: a scalar Result owns nothing, pinned at 0 leaks by `examples/leaks/owned_scalar_wrappers.cell`; resource-bearing payloads remain undesigned | [results](../examples/results.cell), [generics](../examples/future/generics.cell) | M6 |
| OWN-01 five ownership modes and owned default | checked | partial | partial | partial | Resource-bearing copy fields and non-fresh owned-field transfers are refused | [binding modes](../examples/let_binding_modes.cell), [owned field alias](../examples/rejected/owned_field_alias.cell) | M4 |
| OWN-02 move/borrow/alias checking | partial | n/a | n/a | n/a | Exact enforced clauses live in borrowck header | [borrow checker](../src/cell/borrowck.zig) | M2/M4 |
| OWN-03 named-loan NLL | partial | n/a | n/a | n/a | Slices 1/2 enforced; derived loans conservatively refused | [dead loan](../examples/nll_dead_borrow.cell), [aliasing](../examples/rejected/aliasing.cell) | M4 |
| OWN-04 ARC retain/release and transfer | partial | partial | partial | partial | C cleanup gaps; IR preserves return ownership and refuses nonprimitive ARC returns | [ARC](../examples/arc.cell), [ARC return signature](../examples/signatures/arc_string_return.cell) | M2/M4 |
| OWN-05 scope/aggregate/parameter destruction | partial | partial | absent | absent | Nonzero disclosed leak baselines remain | [leak contracts](../examples/leaks/README.md), [C emitter](../src/cell/codegen.zig) | M4 |
| FLOW-01 if/block/match values | checked | lowered | partial | partial | Owning branches constrained by move checker; an `if` branch or `match` arm that always leaves keeps its moves out of the code after it since 2026-09-17 ([early return](../examples/early_return.cell)) | [control flow](../examples/control_flow.cell) | M3/M4 |
| FLOW-02 while/break/continue | checked | lowered | lowered | lowered | Loop moves checked on every path out of the body (R2.a at `continue`, `break` and condition states unioned after the loop) since 2026-09-16. This row read `checked` while five accepted shapes ran as double frees; conservative (a `continue` after a move is refused even when the next iteration reassigns first). A skip-revival `break` is released on the other exits since 2026-09-17 (`after_loop_skip`, leak fixture pinned at 0), and a `return` inside an accepted loop since the same day (leak fixture pinned at 0) | [loops](../examples/loops.cell), [skip-revival jumps](../examples/rejected/skip_revival_jump.cell) | M4/M5 |
| FLOW-03 for/loop/labels/defer | reserved | absent | absent | absent | Must share CFG cleanup | [parser](../src/cell/parser.zig), [lexer](../src/cell/lexer.zig) | M4/M5 |
| EXPR-01 named calls, fields, struct/list literals | checked | partial | partial | partial | Aggregate construction/moves remain restricted | [expressions](../examples/expressions.cell) | M3/M4 |
| EXPR-02 indexing, casts, remaining operators | partial | partial | refused | refused | `a[i]` for `String` and `[Byte]` as `Byte?`, and for `[Int]`/`[Int32]`/`[Float]`/`[Bool]` as the element's optional (2026-09-17; OOB is None). C calls the bounds-checked runtime helpers; LLVM/MLIR refuse together. Casts and remaining operators still absent. Indexed assignment refused | [index](../examples/index.cell), [parser](../src/cell/parser.zig) | M5 |
| PAT-01 scalar/wildcard/binding/variant patterns and guards | partial | partial | partial | partial | Guarded binding patterns refused; arm consumption restricted | [patterns](../examples/pattern_matching.cell), [typecheck](../src/cell/typecheck.zig) | M6 |
| PAT-02 payload/destructuring/exhaustiveness | partial | partial | partial | partial | Wrap patterns `Some`/`None`/`Ok`/`Err` bind a scalar payload in C, and `Ok(owned s)`/`Ok(shared s)` bind an owning String payload in C (2026-09-17; a bare binding on it is refused); LLVM/MLIR lower `Ok`/`Err` and scalar `Some`/`None`; nested patterns and enum payloads remain absent | [optionals](../examples/optionals.cell), [results](../examples/results.cell), [enum payload](../examples/future/enum_payload.cell) | M6 |
| MOD-01 four extensions and stem pairing | checked | n/a | n/a | n/a | Same-directory pairing is a loader concern, not backend lowering | [geometry](../examples/pairing/geometry.cell), [body](../examples/pairing/geometry.body) | M7 |
| MOD-02 module resolution and visibility | partial | absent | absent | absent | use/pub parse without full import/visibility semantics | [loader](../src/cell/load.zig), [parser](../src/cell/parser.zig) | M7 |
| ABI-01 current C runtime and ARM64 classifier | partial | partial | partial | partial | Both IR backends place parameters and returns by `abi.classifyParam`/`classifyReturn` (small returns as exact-width `iN`, 9-16 bytes as `[2 x i64]`, larger ones indirect); stage 10 has no disclosed signature disagreements left. Measured on AArch64/Darwin only; no three-platform qualification | [runtime](../runtime/cell_rt.h), [classifier](../src/cell/abi.zig) | M7 |
| ABI-02 version 2, generated headers, other target ABIs | absent | partial | partial | partial | ABI version 2 (`CELL_RT_ABI_VERSION`) and per-pair Result instance naming for scalar payloads (2026-09-17); owning payloads are sub-projects 2-4; no generated headers or other target ABIs | [completion program](superpowers/plans/2026-09-08-full-language-completion.md) | M7 |
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
