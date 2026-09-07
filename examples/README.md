# Cell examples

Every file here has a **declared, checkable expectation**. That is the point of
the layout: a green `zig build` proves the compiler builds, and proves nothing
whatsoever about whether these programs work. The directories below are what
turns "it parses" into something a reader can trust.

Verified against commit `9fb12af` with a binary built by
`~/.zvm/bin/zig build -Dswift=false`.

## The four directories

| Directory | Expectation | If it breaks |
|---|---|---|
| `examples/*.cell` | must **pass** `cell check` (exit 0) | a regression in the parser or checker |
| `examples/future/` | must **fail** `cell check` | the parser grew a feature: move the file up and rewrite its header |
| `examples/rejected/` | each file declares `// EXPECT: currently-accepted` or `// EXPECT: currently-rejected` | a checker rule landed, or one regressed |
| `examples/pairing/` | `geometry.cell` must **pass**; `geometry.body` must **fail** until stem pairing exists | `geometry.body` passing means the pairing landed |

## Running the checks

There is no gate script, because `tools/` is not part of this change. Run these
from the repository root after `~/.zvm/bin/zig build -Dswift=false`.

Top-level examples, all must pass:

```sh
for f in examples/*.cell; do
  ./zig-out/bin/cell check "$f" >/dev/null 2>&1 \
    && printf 'PASS %s\n' "$f" || printf 'FAIL %s  <-- must pass\n' "$f"
done
```

Future examples, all must fail:

```sh
for f in examples/future/*.cell; do
  ./zig-out/bin/cell check "$f" >/dev/null 2>&1 \
    && printf 'PASS %s  <-- parser grew, move it up\n' "$f" \
    || printf 'fails as expected %s\n' "$f"
done
```

Rejected corpus, each against its own declared expectation:

```sh
for f in examples/rejected/*.cell; do
  want=$(grep -m1 '^// EXPECT:' "$f" | sed 's|^// EXPECT: ||')
  if ./zig-out/bin/cell check "$f" >/dev/null 2>&1; then got=currently-accepted; else got=currently-rejected; fi
  [ "$want" = "$got" ] && printf 'ok       %s\n' "$f" || printf 'MISMATCH %s want=%s got=%s\n' "$f" "$want" "$got"
done
```

## What passes is not what works

`cell check` parses and runs one check. It does not typecheck, and there is no
borrow checker. A file in `examples/` passing means the parser accepted it,
nothing more. Two measured facts keep that honest:

- **Emitted C compiles only for declaration-only files.** `cc -c` on the output
  of `cell emit examples/declarations.cell` and `examples/primitives.cell`
  gives 0 errors. On `examples/hello.cell` it gives 3, and on
  `examples/ownership.cell` it gives 6. The pattern is exact: any file with a
  function body emits C that does not compile, because call sites are not
  name-mangled, struct and list literals are emitted as comments, and struct
  parameters are `void*`.
- **`if` and `match` generate nothing.** Codegen emits `/*if*/` and
  `/*match*/`. `examples/control_flow.cell` and `examples/pattern_matching.cell`
  both pass `cell check` and neither produces working code.

## The top-level examples

| File | What it demonstrates |
|---|---|
| `hello.cell` | the flagship: struct, enum, a function, a call |
| `primitives.cell` | all eleven primitives and their exact C mapping |
| `expressions.cell` | operator precedence and left associativity |
| `bindings.cell` | `let`, `var`, `let mut`, the optional type annotation |
| `control_flow.cell` | `if` / `else` / `else if`, and block expressions |
| `pattern_matching.cell` | `match` and every pattern form that exists |
| `structs_enums.cell` | struct layout emission and per-field ownership |
| `declarations.cell` | bodyless declarations, the C-ABI-first form |
| `ownership.cell` | all five ownership modes, none of them enforced |
| `arc.cell` | the `arc` mode and what the runtime already provides |

## The future corpus

Syntax this specification defines and the parser rejects today. Each file names
the `docs/SPEC.md` section that specifies it.

| File | Missing feature |
|---|---|
| `result.cell` | `Result<T, E>` and generic type arguments |
| `generics.cell` | type parameters on functions |
| `enum_payload.cell` | enum variants carrying data |
| `optional_list.cell` | `[T]?` and nested optionals |
| `unit_type.cell` | `()` in type position |

## The rejected corpus

Programs a conforming Cell implementation must reject. This is the borrow
checker's first test suite: seven of the twelve pass `cell check` today and
must stop passing.

Three of them are not ownership bugs at all, and they are the ones most worth
reading, because each is a case where the compiler accepts a program that means
something other than what it says:

- `while_is_not_a_loop.cell`: `while` is not a keyword, so a loop-shaped
  program parses as a function call plus a discarded block, and does nothing.
- `silent_literals.cell`: `0x1F`, `1_000`, and `1e9` each lex as two tokens and
  emit a different number than the one written.
- `unknown_type.cell`: any type name outside the eleven primitives silently
  becomes `void*`.

## The pairing demo

`geometry.cell` and `geometry.body` show the declaration/implementation split
that `docs/SPEC.md` section 1.2 specifies for the four recognized extensions
(`.cell`, `.cel`, `.body`, `.bod`).

`geometry.cell` passes. **`geometry.body` fails**, with
`unknown identifier 'Quadrant'`, and that failure is the point: every name it
needs is declared in its stem-mate and nothing brings them into scope, because
there is no pairing and no module resolution. The compiler has no notion of a
file extension at all, so `cell check` accepts `.txt` and a file with no
extension just as readily. `geometry.body` starting to pass is the signal that
stem pairing has been implemented.
