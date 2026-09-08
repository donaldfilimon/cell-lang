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
| `examples/pairing/` | both `geometry.cell` and `geometry.body` must **pass** now that stem pairing is implemented | `geometry.body` failing means pairing regressed |

## Running the checks

`tools/check.sh` is the gate: build, tests (with the count printed), the four
corpus contracts below, backend agreement (LLVM vs MLIR must reach the same
verdict), and execution (emit, `cc`, link, run, and compare the output) for
the key cases. Run it from the repository root:

```sh
tools/check.sh
```

Its own header comment records why it exists: these four loops used to be the
only way to check the corpus, and they were retyped by hand more than a dozen
times in a single session, each retype a chance to run a subtly different
check and believe a different answer. They are kept below because they
document WHAT the four contracts are, not as instructions to paste and run by
hand instead of the gate.

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

## Checking a file through every backend

`cell check` is one gate; agreement between the backends is another, and only
`backends.cell` exercises it. All three must print `24`:

```sh
# C
./zig-out/bin/cell emit examples/backends.cell > /tmp/b.c
cc -I runtime /tmp/b.c runtime/cell_rt.c -o /tmp/b_c && /tmp/b_c

# LLVM IR   (cc, NOT zig cc: `zig cc -x ir` fails outright)
./zig-out/bin/cell emit --target=llvm examples/backends.cell > /tmp/b.ll
cc -Wno-override-module -x ir /tmp/b.ll -c -o /tmp/b.o
cc /tmp/b.o runtime/cell_rt.c -I runtime -o /tmp/b_llvm && /tmp/b_llvm

# MLIR      (tools live in the Homebrew keg, not on PATH)
L=/opt/homebrew/opt/llvm/bin
./zig-out/bin/cell emit --target=mlir examples/backends.cell > /tmp/b.mlir
$L/mlir-opt /tmp/b.mlir --expand-strided-metadata --finalize-memref-to-llvm \
    --convert-cf-to-llvm --convert-func-to-llvm --convert-arith-to-llvm \
    --reconcile-unrealized-casts -o /tmp/b_low.mlir
$L/mlir-translate --mlir-to-llvmir /tmp/b_low.mlir -o /tmp/b_m.ll
$L/llc -filetype=obj /tmp/b_m.ll -o /tmp/b_m.o
printf 'extern void cell_main(void);\nint main(void){cell_main();return 0;}\n' > /tmp/drv.c
cc /tmp/b_m.o /tmp/drv.c runtime/cell_rt.c -I runtime -o /tmp/b_mlir && /tmp/b_mlir
```

Note `hello.cell` is NOT in this set. It declares a struct, and the MLIR
backend carried no structs. It does now (`!llvm.struct`), so `hello.cell`
runs through all three and prints `42` from each. What all three still refuse
is `[T]`, which SPEC 3.3 says has no representation at all.

## What `cell check` covers

`cell check` parses, typechecks, and borrow-checks. A file in `examples/`
passing means those three stages accepted it. Emit is a separate claim, and
both halves of it are measured over every file here rather than a chosen few:

- **`cc -std=c11 -Wall -Wextra -c`: they all compile.** `arc.cell` was the
  last one that did not, and now does.

  **Read that as a statement about this directory, not about the language,
  and here is a measured hole that shows the difference.** No file here
  returns a `String` from a body. `primitives.cell:33` only *declares*
  `take_string(shared v: String) -> String` with no body, so this stage has
  never once compiled a conversion from a string literal to an owned
  `String`. Six one-line programs pass `cell check` with exit 0 and emit C
  that this command rejects outright, as errors rather than warnings, so the
  absent `-Werror` does not save them: a `return` from `-> String`, a `let
  owned` initializer, a `var owned` initializer, an `owned` call argument, a
  struct-literal field, and an assignment's right side. A string literal is a
  16-byte borrowed `cell_str_t` and an owned `String` is a 24-byte
  `cell_string_t`; nothing converts between them outside the `arc` direction.
  `AGENTS.md` carries the full record. A fixture would turn this stage red,
  which is correct, so it lands with the fix rather than before it.

  The reusable point is that a corpus-wide check is only as strong as the
  shapes the corpus contains, and the shapes it lacks are invisible by
  construction. That is the sanitizer lesson from `AGENTS.md` one stage over:
  at one commit the entire corpus was AddressSanitizer-clean while a real
  use-after-free was live. A magnifier is not a net.
- **Link and run**, measured 2026-09-08: seven link on their own
  (`hello` 42, `backends` 24, `loops` 55, `while_is_now_a_loop` 10,
  `arc_return_field` 7, and `ownership` and `borrows` both silent at exit 0);
  two more link once their host is added (`arc` 13 with `arc_host.c`,
  `write_through` 142 with `write_through_host.c`); the rest do not link for
  one reason, and it is not a codegen defect: they declare no `pub fn main()`
  with a body, so no C `main` is emitted and the link stops at `_main`.

**Counts are deliberately not stated here as totals.** This section said
"fourteen" for two days after the corpus reached seventeen, and its
six-plus-seven arithmetic stopped adding up at the same moment. A count in
prose is stale the next time anyone adds a file, and this corpus grew by three
in one evening. `tools/check.sh` runs every contract on this directory as it
actually is, so **the gate is the authority and this file is the explanation.**
Run it rather than trusting a number here, including this paragraph's.

`if` / `match` / blocks / struct and list literals lower to C, not placeholder
comments.

Still not implemented: loops other than `while`, generics, `Result<T,E>`, enum
payloads, and hex / underscore / exponent literals. `arc` retain/release is
implemented in the C backend, with the gaps `docs/OWNERSHIP.md` R11 names.
Stem pairing and `while`/`break`/`continue` are implemented; `for` and `loop`
are not.

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
| `arc.cell` | the `arc` mode: boxing, call-site retains, the `shared` non-retain, and scope release. Prints `13`, a refcount measurement. Needs `arc_host.c`, below |
| `backends.cell` | the cross-backend agreement case: scalar-only, carried by C, LLVM and MLIR alike, and all three print `24` |
| `borrows.cell` | every borrow spelling (`shared`/`&`, `exclusive`/`&mut`/`&var`/`&exclusive`) and the keyword-wins rule for mixing |
| `loops.cell` | `while`, both spellings, plus `break` and `continue`; prints 55 through all three backends |
| `while_is_now_a_loop.cell` | the same program that once passed and silently did nothing, now looping correctly; its header records all four meanings it has had |

## Running `arc.cell`, the one example with a C host

`arc.cell` declares `observe` and `inspect` without bodies, because what it
demonstrates is the `arc` and `shared` calling conventions at the C boundary.
`examples/arc_host.c` defines them, and `observe` reads
`cell_arc_strong_count`, which no Cell body can reach. That is why the example
is not self-contained: without the host it would prove the emitted program does
not crash, not that the retains balance.

```sh
./zig-out/bin/cell emit examples/arc.cell > /tmp/arc.c
cc -std=c11 -Wall -Wextra -Werror -I runtime    /tmp/arc.c examples/arc_host.c runtime/cell_rt.c -o /tmp/arc && /tmp/arc
# 13
```

13 is a measurement, not arithmetic: `observe` returns the strong count it was
handed (3 each time, the original plus the `alias` handle plus that call's own
retain) and `inspect` returns the borrowed view's length, 7. Under `leaks` the
program reports `0 leaks for 0 total leaked bytes`, because the host releases
its `arc` parameter as `runtime/cell_rt.h` section 7 requires. A Cell body
would not: the C backend drops no parameter, so a Cell-bodied `arc` parameter
leaks its caller's retain. `tools/check.sh` runs this case through
`run_c_host`.

The LLVM and MLIR backends refuse this file, identically and on purpose.

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
R14 files are rejected, and so is call-site mismatch (R15) since `67529a9`:
the parser now keeps the argument ownership prefix and borrowck compares it
against the parameter.

`owned_from_borrow.cell` carries R18, an `owned` binding initialized from a
borrow, and it is one file rather than nine because the point is that the nine
spellings agree. Before R18 they did not: six were AddressSanitizer double
frees at exit 134 and two exited 0 while silently moving the lender under a
written `shared` prefix. A refused program emits no C, so the ASan stage cannot
pin this either; the `EXPECT` line is what does.

Two files carry R10, and they differ on the axis that made the rule escape
twice, so keep both:

- `arc_to_owned.cell`: the `arc`-ness comes from a **binding annotation**
  (`let arc xs = ...`, then `take(owned xs)`).
- `arc_call_to_owned.cell`: it comes from a **signature's return type**
  (`fresh() -> arc [Int]`, then `take(owned fresh())`). This one was a live
  AddressSanitizer double free at exit 134, not a masked one, and neither the
  place machinery nor the expression-shape widening that fixed the first file
  could see it. A refused program emits no C, so the ASan stage cannot run
  either; the rejected loop's `EXPECT` line is what pins them.

Two other files are not ownership bugs at all. One is currently-rejected for
the wrong reason (unknown identifier); the other, `unknown_type.cell`, is still
accepted:

- `silent_literals.cell`: currently-rejected. `0x1F`, `1_000`, and `1e9` each
  lex as two tokens. Today the checker reports `unknown identifier 'x1F'`;
  the lexer still splits the literal.
- `unknown_type.cell`: currently-accepted. Any type name outside the eleven
  primitives silently becomes `void*`.

A third file used to live here for the same reason: `while_is_not_a_loop.cell`,
rejected as `unknown identifier 'while'` because `while` was not yet a
keyword. Once `while` became a reserved word and then grew loops, the file was
moved and renamed rather than deleted, since its SOURCE never changed while
its MEANING changed four times. It now lives at
`examples/while_is_now_a_loop.cell` (see the top-level table above), and its
own header comment records the full history.

## The pairing demo

`geometry.cell` and `geometry.body` show the declaration/implementation split
that `docs/SPEC.md` section 1.2 specifies for the four recognized extensions
(`.cell`, `.cel`, `.body`, `.bod`).

Both `geometry.cell` and `geometry.body` pass `cell check`. The body is paired
with the module by filename stem in the same directory, so `Point` and
`Quadrant` resolve. A `.body` file with no `.cell`/`.cel` stem-mate is an
error that names the body and the missing module. `.cel` is an alias of
`.cell`. `.txt` and extensionless paths still load as a standalone module.
