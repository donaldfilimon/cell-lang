# Cell examples

Every file here has a **declared, checkable expectation**. That is the point of
the layout: a green `zig build` proves the compiler builds, and proves nothing
whatsoever about whether these programs work. The directories below are what
turns "it parses" into something a reader can trust.

Verified with a binary built by `~/.zvm/bin/zig build -Dswift=false`.

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

## What `cell check` covers

`cell check` parses, typechecks, and borrow-checks. A file in `examples/`
passing means those three stages accepted it. Body-bearing emit compiles for
`hello.cell`, `control_flow.cell`, and `ownership.cell`: `cell emit
examples/hello.cell` compiles with `cc -c`, and linked against
`runtime/cell_rt.c` it prints `42`. `examples/arc.cell` does not compile until
arc boxing exists. `if` / `match` / blocks / struct and list literals lower
to C, not placeholder comments.

Still not implemented: loops, generics, `Result<T,E>`, enum payloads, hex /
underscore / exponent literals, stem pairing, and `arc` retain/release.

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
| `ownership.cell` | all five ownership modes; R2/R3/R5/R8/R14 enforced |
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

Programs a conforming Cell implementation must reject. Each file declares
`// EXPECT: currently-accepted` or `currently-rejected`. R2, R3, R5, R8, and
R14 files are rejected. Call-site mismatch (R15) is still accepted because
the parser discards argument ownership prefixes.

Three of them are not ownership bugs at all. Two are currently-rejected for
the wrong reason (unknown identifier); only `unknown_type.cell` is still
accepted:

- `while_is_not_a_loop.cell`: currently-rejected. `while` is not a keyword, so
  a loop-shaped program would parse as a call plus a discarded block. Today
  `cell check` reports `unknown identifier 'while'`. If a function named
  `while` existed, this would compile and silently not loop.
- `silent_literals.cell`: currently-rejected. `0x1F`, `1_000`, and `1e9` each
  lex as two tokens. Today the checker reports `unknown identifier 'x1F'`;
  the lexer still splits the literal.
- `unknown_type.cell`: currently-accepted. Any type name outside the eleven
  primitives silently becomes `void*`.

## The pairing demo

`geometry.cell` and `geometry.body` show the declaration/implementation split
that `docs/SPEC.md` section 1.2 specifies for the four recognized extensions
(`.cell`, `.cel`, `.body`, `.bod`).

Both `geometry.cell` and `geometry.body` pass `cell check`. The body is paired
with the module by filename stem in the same directory, so `Point` and
`Quadrant` resolve. A `.body` file with no `.cell`/`.cel` stem-mate is an
error that names the body and the missing module. `.cel` is an alias of
`.cell`. `.txt` and extensionless paths still load as a standalone module.
