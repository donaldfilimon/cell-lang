# The Cell Language Specification

Version 0.1.0 (draft).

**Snapshot: committed `src/` as of commit `9fb12af`, 2026-09-06.** The compiler
under `src/` and the runtime under `runtime/` are being actively rewritten by
another author while this document is being written, and both moved several
times during that window. Every status claim below was re-verified against a
binary built from `a690a8c`, whose `src/` tree is byte-identical to `9fb12af`'s
(`git diff a690a8c 9fb12af -- src/` is empty; the intervening commits touch
`runtime/` and documentation only). Uncommitted work in progress in the working
tree is deliberately excluded, because it does not yet build.

If a claim here disagrees with the source, believe the source and re-verify:
`git log a65a586..HEAD` shows what has changed since this specification was
first drafted. Several statuses below were already corrected once mid-drafting,
when the parser gained struct-literal restriction, postfix chains, `match`, and
source spans.

Cell is a systems language that blends Rust ownership and algebraic data types,
Swift value/reference clarity and ergonomics, and Zig explicit control with a
C-ABI-first ethos. The reference toolchain is written in Zig
`0.17.0-dev.2018+ab30a0b9a` and emits C.

This document specifies the language. It is not a description of a finished
compiler. Every construct carries a status tag, assigned by reading `src/` and
by running the compiler, never by assuming that "it parses" means "it works".

---

## 0. How to read this document

### 0.1 Status tags

| Tag | Meaning |
|---|---|
| **implemented** | The compiler accepts it and a later stage acts on it correctly. Verified by running `cell check` / `cell emit`. |
| **parsed, not enforced** | The parser accepts the syntax and records it faithfully, but no later stage checks its meaning or lowers it. |
| **designed, not implemented** | Specified here. The compiler today either rejects it outright or ignores it. |

**implemented** never means safe, optimized, or complete. It means the observed
behavior of a binary built from `9fb12af` matches this specification for the
cases tested. Section 12 is the full construct-by-construct index and the
counts in section 0.2 are derived from it.

Note a distinction that recurs: a construct can be **implemented in the parser
and not lowered by codegen**. Those are tagged **parsed, not enforced** with
the reason stated. `if` and `match` used to be in that column (`/*if*/` /
`/*match*/` placeholders); they now lower to C (section 0.6). Call-site
ownership prefixes have left that column too (section 0.7). The remaining
parser-only cases include `T?`, `[T]` as a type, and `use`.

### 0.2 Status summary

| Status | Constructs |
|---|---|
| implemented | 86 |
| parsed, not enforced | 8 |
| designed, not implemented | 55 |
| **total** | **149** |

Counted from the section 12 index, not estimated.

The headline consequence: **the front end, a typechecker, a borrow checker for
R2/R3/R5/R8/R14, and C lowering for the flagship examples are real.** As of
the working tree the lexer, parser, AST, diagnostics, typechecker, and
borrowck are wired into `cell check`. `if` / `else`, `match`, blocks, struct
literals, list literals, and mangled calls lower to C. What is still designed
includes loops other than `while`, generics, `Result<T,E>`, and NLL. `arc`
retain/release is implemented in the C backend, with the gaps R11 of
`docs/OWNERSHIP.md` names. Stem
pairing (section 1.2) and R15 call-site prefixes (section 0.7) have since
landed and are not counted in 0.2. `docs/OWNERSHIP.md` is the normative rule
list; section 12 is the construct-by-construct index.

### 0.3 Verification method

Everything tagged **implemented** was checked by building the compiler and
running it:

```sh
cd ~/dev/active/cell-lang
~/.zvm/bin/zig build -Dswift=false
./zig-out/bin/cell check <file>
./zig-out/bin/cell emit  <file>
```

`cell check` exits `0` on success and `1` on a parse or check error (measured).
Where this document says "measured", a probe file was run through that binary
and the output read. Where it says the emitted C does or does not compile, the
output was piped through `cc -c` and the errors counted.

The Swift-linked build path (`-Dswift=true`, the default) hardcodes
`/Applications/Xcode-beta.app` library paths in `build.zig` and was **not**
exercised, so nothing here depends on it.

### 0.4 Things this specification deliberately does not claim

Cell has no measured performance characteristics, no memory-safety guarantee,
no ABI stability guarantee, and no thread-safety guarantee beyond one narrow
fact: `cell_arc_t` refcounts in `runtime/cell_rt.c` are atomic as of `562f116`.
Nothing else in the runtime is thread safe, and `cell_arena_t` explicitly is
not. Any safety property this document describes is a property of the
*specified* language, to be delivered by a checker that does not exist yet.

### 0.5 Delta since the snapshot: commit `8dd5673`

The section 12 index is pinned to `src/` as of `9fb12af`. While this document
was being finalized, `8dd5673` ("a real typechecker with scopes, types, and
span-carrying errors") landed: a rewrite of `src/cell/typecheck.zig` of roughly
780 lines with new entry points in `src/root.zig` and `src/main.zig`. The index
was not re-derived for it, because doing so would mean re-verifying 149 rows
against a tree that moved four times in one evening. Pretending it does not
exist would be worse, so this section records the measured delta instead.

Measured against a binary built from `8dd5673`:

| Claim above | Working-tree reality |
|---|---|
| "there is no type representation" (0.2) | there is one: `!c` on an `Int` is rejected with `operator '!' requires a Bool operand, found Int` |
| name resolution is designed, not implemented (6.2) | implemented: `print(n)` with no declaration gives `unknown identifier 'print'` |
| chained comparison is not rejected (5.1) | rejected, by a type rule: `operator '<' cannot be applied to Bool and Int` |
| "the only rule the compiler enforces is immutable assignment" (section 4) | no longer true; operator typing and name resolution are enforced too |
| the symbol table is module-wide and unscoped (7.3 bullet 3, OWNERSHIP.md 0.4) | **fixed**, measured: a `let x` in `a()` is no longer visible in `b()`, which now reports `unknown identifier 'x'` |
| parse diagnostics do not reach the CLI (11) | check diagnostics now render with the source line and a caret |

Three claims above were re-tested against that `8dd5673` binary and still held
then: unknown type names were still accepted silently as `void*`, `if` and
`match` still lowered to `/*if*/` and `/*match*/`, and no ownership rule was
enforced. The whole of `examples/rejected/` was re-run: seven of the thirteen
files still passed, including every use-after-move, aliasing, escaping-borrow,
and call-site-mismatch case. Section 0.6 records what later work changed:
`if` / `match` now lower to C, and R2/R3/R5/R8/R14 are enforced. Unknown type
names remain accepted as `void*`.

### 0.6 Delta: ownership enforcement and body-bearing emit

Later work wired `src/cell/borrowck.zig` into `cell check` and replaced
placeholder codegen. Measured against a binary built with `-Dswift=false`:

- R2, R3, R5, R8, and R14 are enforced. `examples/rejected/use_after_move.cell`,
  `move_out_of_borrow.cell`, `aliasing.cell`, `escaping_borrow.cell`,
  `immutable_assign.cell`, and `field_assign_immutable.cell` are
  `currently-rejected`. Call-site prefixes (R15) were still discarded at this
  point, so `callsite_mismatch.cell` remained `currently-accepted`; section
  0.7 supersedes that.
- `if` / `else`, `match`, blocks, struct literals, list literals, and calls
  lower to real C. `cell emit examples/hello.cell` compiles with `cc -c`.
  Linked against `runtime/cell_rt.c` it prints `42`.
- Unknown type names, hex/underscore/exponent literals, loops, generics,
  `Result<T,E>`, enum payloads are unchanged. Stem pairing of `.cell`/`.cel`
  with `.body`/`.bod` is implemented (section 1.2).

Section 12 rows that this delta moved are retagged below. Unshipped rows stay
as they were.

Two files in `examples/rejected/` are now rejected **for the wrong reason**, and
that distinction is worth preserving rather than celebrating.
`silent_literals.cell` fails with `unknown identifier 'x1F'`, which catches the
second token rather than the malformed literal, and `while_is_not_a_loop.cell`
fails with `unknown identifier 'while'`, which is name resolution landing on
the right line by luck. Neither underlying language defect is fixed. Each file
says so in its header.

Re-derive the index from the source before trusting the counts in 0.2 if
`git log` shows further commits after `8dd5673` touching `src/`. The counts are
a measurement with a date on it, not a standing property of the language.

### 0.7 Delta: call-site ownership prefixes (R15)

Measured against a binary built from `67529a9` with `-Dswift=false`:

- The parser now keeps the ownership keyword written on a call argument
  (`b39c158`), `refKind` peels the annotated wrapper (`9917ec7`), and borrowck
  compares the written mode against the callee's parameter (`67529a9`). R15 is
  **implemented**. `examples/rejected/callsite_mismatch.cell` is
  `currently-rejected` with `error: 'take' expects parameter 'b' as 'owned',
  but the argument is passed as 'shared'`, and its `// EXPECT:` header was
  updated to match.
- `src/cell/borrowck.zig`'s file header is the authoritative list of the rules
  the checker implements. Read it rather than any prose list in this document.

**The 0.2 counts are now stale by at least the R15 row**, which section 12
still tags *designed, not implemented* in its Ownership table, and by the stem
pairing rows of section 1.2. Re-deriving the 149-row index against the current
tree is a separate, counted task; it was deliberately not attempted here rather
than guessed at. Nothing else in section 12 was re-verified for this delta.

### 0.8 Delta: the union with CELL v2.0, and three backends

Two changes landed on 2026-09-07 that this index does not yet count. Recorded
as a delta rather than patched into 0.2, for the reason 0.7 already gives: the
149-row index is a measurement with a date on it, and re-deriving it is a
separate counted task.

**A second Cell exists, and this specification now says so.** A different
implementation, "CELL v2.0", uses the same name and the same `.cell`/`.cel`
extensions for a Zig-shaped language with error unions, `error_scope`/`raise`,
and its own package manifest. Donald's decision is a deliberate union of the
two surfaces: constructs are admitted one at a time, on evidence, and the
ownership model and the C ABI are not up for negotiation. What has landed:

- **`&var x` is a third spelling of `&mut x` and `&exclusive x`** (section 6.5).
  It builds the identical AST node, so no later stage has a case for it; R15
  compares it against the parameter exactly as it does the others. Measured:
  `take(&var buf)` against an `owned` parameter is rejected with "the argument
  is passed as 'exclusive'".
- **A trailing `;` after an item is accepted and ignored** (section 7.1 already
  made semicolons optional on statements; items were the exception). A `;`
  cannot start an item, so this is unambiguous.

**Explicitly refused, with the reason, so the decision is not re-litigated:**

| Refused | Why |
|---|---|
| `switch` | `match` is implemented and lowers to C. In the other tree `kw_match` is declared but absent from its keyword map, so `match` does not even lex there, and its own README states "one construct, one keyword". Admitting `switch` also needs `\|x\|` captures, and `\|` is reserved here for pattern alternatives (2.10). |
| `i32` / `f64` | Section 3.1 is normative and exhaustive. The largest known hole in the compiler is that an unrecognized type name silently becomes `void*`; the fix is an enumeration of known names, and doubling that enumeration for pure synonyms widens the hole for no expressiveness. |
| `@import("std")` | Neither implementation resolves modules (8.4). Adding `@` to the lexer to admit a namespace that binds nothing is surface debt. |
| `const Foo = struct { }` | A second item grammar for a meaning the existing one already expresses. The genuinely missing feature underneath it, a top-level `const` value binding, is worth having on its own and is not this. |
| macros | The other implementation states outright that its expander is not hygienic. A construct that can invisibly introduce a binding can silently change which place a move kills, and the diagnostic would point into expanded source. That is not deferrable in a language whose claim is that ownership is checkable. |
| `.bod` as a package manifest | Section 1.2 is normative: `.bod` is a body file. See below. |

**The `.bod` collision, stated normatively.** Another implementation reads
`.bod` as a package manifest. This specification does not, and a conforming
implementation MUST treat `.bod` and `.body` as body files paired to a
`.cell`/`.cel` module by filename stem, per section 1.2. The other reading is
recorded here only so the conflict is visible rather than discovered.

**Union stage 4 landed too, and it is the one that changed the language rather
than its surface: Cell has loops.** `while`, `break` and `continue` are
implemented across all three backends; `examples/loops.cell` prints 55 through
each. It came with `docs/OWNERSHIP.md` **R2.a**, because a loop is a back edge
and section 0.3 of that document bought its simplicity by assuming there were
none: a place declared outside a loop and moved inside it is now rejected,
since the next iteration would use it after the move. Reassigning before the
body ends revives it (R3a) and the loop is accepted.

One corpus file moved as a result, and the move is the evidence.
`examples/rejected/while_is_not_a_loop.cell` is now
`examples/while_is_now_a_loop.cell`, unchanged as a program, having meant four
different things: it passed and silently did nothing; then failed by name
resolution; then failed as a parse error once `while` was reserved; and now
passes and actually loops, returning 10 through C, LLVM and MLIR alike.

**Union stage 3 also landed:** SPEC 2.5's reserved words are real keywords.
Measured safe before the change, by stripping comments from every file under
`examples/` and `stdlib/` and grepping for all 24 words as identifiers: exactly
one hit, in the file written to break there.

That change exposed a defect it did not cause. `while (c) { }` became a PARSE
error, and a parse error had never reached the CLI on this path before, so it
escaped as a raw Zig error and printed a **stack trace** instead of a caret.
The parser already recorded the failure and could push it into a bag; nothing
called that. `load.zig` now renders it, and a syntax error reads like every
other diagnostic.

**Three backends.** `cell emit` now takes `--target=c|llvm|mlir`. C remains the
only backend that lowers the whole language. The LLVM IR and MLIR backends go
through a typed IR (`src/cell/hir.zig`) and are scalar-first: `String`, `[T]`,
`T?`, `Result`, `arc`, and (for MLIR) structs produce a `cannot lower`
diagnostic at the offending span rather than wrong output. Both are verified by
executing what they emit. `examples/backends.cell` prints `24` through all
three. Section 10's C ABI contract is unchanged and remains normative for the
C backend.

---

## 1. Source files and modules

### 1.1 Encoding and file extensions

**Status: designed, not implemented.**

A Cell source file is UTF-8 text. The lexer classifies only ASCII
(`std.ascii.isAlphabetic`, `std.ascii.isDigit`), so a non-ASCII byte outside a
string literal or comment produces an `invalid` token.

Cell recognizes four source file extensions in two roles:

| Extension | Role |
|---|---|
| `.cell` | module file |
| `.cel` | module file (alias of `.cell`) |
| `.body` | body file |
| `.bod` | body file (alias of `.body`) |

`.cel` is an exact alias of `.cell` and `.bod` is an exact alias of `.body`.
The two *pairs* are not aliases of each other.

**The chosen reading: `.cell`/`.cel` declares, `.body`/`.bod` implements.**
This is a deliberate decision recorded here, not an inference left open. The
alternative reading, that all four are aliases and the declaration split lives
in syntax, was rejected for three reasons. First, "body" already has a precise
meaning in this compiler: `FnDef.body` is `?[]Stmt`, and a function with
`body == null` is exactly a declaration without an implementation, a form the
parser already accepts (`pub fn f(shared a: Int) -> Int;`). Second, a
C-ABI-first language needs a header-shaped artifact anyway, and a declaration
file is that artifact. Third, four aliases for one thing is not a design, it is
four spellings.

### 1.2 Module and body pairing

**Status: implemented.** A body file is paired with a same-directory `.cell` or
`.cel` stem-mate before check. `cell check examples/pairing/geometry.body`
resolves `Point` and `Quadrant` from `geometry.cell` and exits 0. A body with
no stem-mate is an error naming the body and the missing module. A module file
with no body remains legal. A `pub` definition in the body must have a matching
module declaration (rule 8), must not duplicate a module-side body (rule 10),
and must agree on arity, parameter ownership, parameter types, and return type
(rule 11).

1. A **module file** (`.cell`/`.cel`) may contain declarations, definitions, or
   both. Every example under `examples/` is a module file that does both, and
   that stays legal.
2. A **body file** (`.body`/`.bod`) supplies definitions for declarations made
   in its module file. It is paired **by filename stem within the same
   directory**: `geometry.cell` pairs with `geometry.body`.
3. Pairing carries no syntax. There is no `module` declaration inside the file
   and no `use` between the pair. Stem pairing was chosen over an in-file
   module declaration because `build.zig` can express it without the build
   graph parsing Cell, and over an explicit `use` because a body is not a
   dependency of its declaration, it is the same module.
4. It is an error for one stem in one directory to have both `.cell` and `.cel`
   files, or both `.body` and `.bod` files. The aliases exist for taste, not
   for simultaneous use.

   > `error: ambiguous module 'geometry': both geometry.cell and geometry.cel exist`

5. A body file whose stem has no module file is an error. A body cannot stand
   alone, because there is nothing for its `pub` items to implement.

   > `error: body file 'geometry.body' has no module file (expected geometry.cell or geometry.cel)`

6. A module file with no body file is **legal and common**. That is the normal
   case, and it is what `stdlib/prelude.cell` is.
7. A `pub fn` declared without a body in the module file and not defined in the
   body file is **legal**. It is an external symbol: the C-ABI-first story, and
   the mechanism by which the prelude declares host intrinsics.
8. A `pub` item defined in a body file with no matching declaration in the
   module file is an error.

   > `error: 'grow' is defined in geometry.body but not declared in geometry.cell`

9. A non-`pub` item in a body file needs no declaration. It is private to the
   pair.
10. A function with a body in the module file and also a body in the body file
    is a duplicate definition error.

    > `error: 'grow' already has a body in geometry.cell`

11. A declaration and its definition must agree exactly on name, arity, each
    parameter's ownership annotation, each parameter's type, and the return
    type. Parameter *names* need not match.

    > `error: 'grow' body does not match its declaration: parameter 1 is declared 'exclusive Buffer' but defined 'owned Buffer'`

12. A single file may contain both declarations and definitions in every case
    above. The split is a filing convention the compiler enforces, not a
    restriction on what one file may say.

`src/cell/load.zig` classifies the path, finds the stem-mate, and merges
module declarations into the body unit. `cell check` / `dump` / `emit` all go
through that load. `.txt` and extensionless paths still load as a standalone
module. `examples/pairing/` is the worked pair.

### 1.3 Compilation unit

**Status: implemented (single file only).**

`cell <command> <file>` compiles exactly one file. There is no module
resolution, no include path, no package manager, and no linking of a module to
its body file. A `use` declaration (section 8.4) is recorded and emitted as a C
comment.

---

## 2. Lexical structure

### 2.1 Whitespace and line terminators

**Status: implemented.**

Space, tab, carriage return, and newline are trivia. Newlines are not
significant: Cell has no offside rule and no automatic semicolon insertion.
Statement boundaries come from the grammar, not from line breaks (section 7.1).

### 2.2 Comments

**Status: implemented.**

```cell
// line comment, runs to the end of line
/* block comment */
```

Block comments **do not nest**. `/* /* */` closes at the first `*/`. An
unterminated block comment consumes the rest of the file without producing a
diagnostic.

`/// doc comment` is lexed as an ordinary line comment. Doc comments are
**designed, not implemented**: attaching them to the following item and
carrying them into generated C is future work, and nothing in the AST can hold
them today.

### 2.3 Identifiers

**Status: implemented.**

```
ident_start    = ASCII letter | "_"
ident_continue = ident_start | ASCII digit
identifier     = ident_start ident_continue*
```

Identifiers are ASCII only and case-sensitive.

`_` is an ordinary identifier at the lexical level. It acquires meaning in
exactly one place: `parsePattern` compares the lexeme and treats `_` as the
wildcard pattern (section 9). Everywhere else `_` is a name, so `let owned _ =
f()` binds a variable called `_`. Making `_` a reserved wildcard everywhere is
**designed, not implemented**.

Unicode identifiers are **designed, not implemented**.

### 2.4 Keywords

**Status: implemented.**

Nineteen words are reserved and can never be used as identifiers:

```
fn      let     var     mut     struct   enum
if      else    match   return  use      pub
true    false
owned   shared  exclusive  arc  copy
```

The five ownership words are full keywords, not contextual ones. `arc` cannot
be a variable name.

### 2.5 Reserved for future use

**Status: implemented.** These lex as keywords as of the union stage recorded
in 0.8. None of them has a parser rule yet, which is the point: using one as a
name is now a parse error rather than a silent misreading.

The following are reserved by this specification so that programs do not come
to depend on using them as names:

```
while   for     loop    break   continue  in
impl    trait   where   type    const     static
self    Self    as      is      defer     async
await   yield   import  export  extern    unsafe
```

**This is not a cosmetic reservation, and `while` shows why.** Since `9fb12af`
a brace-delimited block is a valid expression (section 6.10), so
`while (c) { total = total + 1 }` used to **parse cleanly and pass `cell check`**:
`while` was an identifier, `while (c)` was a call to a function named `while`,
and the block that followed was a separate expression statement, evaluated and
discarded. A program written in the belief that Cell has loops compiled and did
nothing.

Measured now: `cell check examples/rejected/while_is_not_a_loop.cell` reports
`error: expected expression` with the caret on `while`, and exits 1. That file
records the whole sequence, including the middle state where it was rejected by
name resolution rather than by this rule.

**Reserving a word does not implement it.** Cell still has no loops of any kind
(section 7.6). Only `while`, `break` and `continue` are scheduled to gain
parser rules; the rest are reserved and nothing more.

### 2.6 Integer literals

**Status: implemented (decimal only).**

```
int_literal = ASCII digit+
```

Decimal digits only. There is no sign in the literal itself: `-1` is unary
negation applied to `1` (section 6.5). One exception exists inside patterns,
where `-` followed by a numeric literal is folded into a negative literal
pattern (section 9), because a pattern is not an expression and cannot contain
a unary operator.

**Hexadecimal (`0x1F`), binary (`0b1010`), octal (`0o17`), and underscore digit
separators (`1_000`) are designed, not implemented, and they fail dangerously.**
The lexer stops at the first non-digit, so `0x1F` lexes as the integer `0`
followed by the identifier `x1F`, and `1_000` lexes as `1` followed by `_000`.
Both are accepted by `cell check` with exit code 0. Measured: `let copy x =
0x1F` emits `int64_t x = 0; x1F;`. A conforming implementation must either
support these forms or reject them; silently producing a different number is
not an option. See `examples/rejected/silent_literals.cell`.

Integer literals are parsed into `i64` by `std.fmt.parseInt`. A literal that
does not fit produces `error.InvalidLiteral`. There is no arbitrary-precision
literal type and no literal suffix.

### 2.7 Float literals

**Status: implemented (simple decimal form only).**

```
float_literal = ASCII digit+ "." ASCII digit+
```

A digit is required on both sides of the point. `1.` and `.5` are not float
literals: `1.` lexes as `1` followed by `.`, and `.5` as `.` followed by `5`.
Exponent notation (`1e9`, `1.5e-3`) and hexadecimal floats are **designed, not
implemented**, and mis-lex in the same silent way as section 2.6. Float
literals are parsed into `f64`.

### 2.8 String literals

**Status: implemented (lexing). Escape processing: designed, not implemented.**

```
string_literal = '"' character* '"'
```

The lexer skips the character after a backslash so that `\"` does not terminate
the literal, and `stringValue` in the parser strips the surrounding quotes.
**Nothing translates escapes.** The bytes `\` and `n` survive into the AST and
are written verbatim into the emitted C, where the C compiler then interprets
them. This works by coincidence for the escapes C shares with Cell, and it is
specified as a defect: a conforming implementation processes `\n`, `\t`, `\r`,
`\\`, `\"`, `\0`, and `\u{...}` itself and re-escapes on emission.

An unterminated string literal runs to end of file and produces **no
diagnostic**. Specified as an error:

> `error: unterminated string literal`

Multi-line strings, raw strings, and interpolation are **designed, not
implemented**.

### 2.9 Boolean literals

**Status: implemented.** `true` and `false` are keywords, not identifiers.

### 2.10 Operators and punctuation

**Status: implemented.**

```
( ) { } [ ]   , : ; .
->  =>  ?
+  -  *  /
=  ==  !=  <  <=  >  >=
&  &&  ||  !
```

That is the complete lexical operator set. There is no `%`, no `**`, no
bitwise `|` `^` `~`, no shifts `<<` `>>`, no compound assignment `+=`, no `++`,
no `::`, no `..`, and no `|` as a pattern alternative. A bare `|` lexes as
`invalid`. All of those are **designed, not implemented**.

### 2.11 Token spans

**Status: implemented.**

Every token carries `start` and `end` byte offsets into the source buffer plus
a 1-based `line` and `column`. A lexer test asserts that every token's byte
range slices back to its own lexeme, and another asserts that line and column
survive comments, newlines, and strings. Those spans are what makes section 11
possible.

### 2.12 Invalid input

**Status: parsed, not enforced.**

Any other byte produces an `invalid` token, which stops tokenization. The
parser then fails. The failure is recorded with a span and a message but is not
printed by the CLI; see section 11.

---

## 3. Types

### 3.1 Primitive types and their C mapping

**Status: implemented.**

`Generator.mapPrimitive` in `src/cell/codegen.zig` fixes these names. This
table is normative and exhaustive:

| Cell | C emitted today | Notes |
|---|---|---|
| `Int` | `int64_t` | the default integer |
| `Int64` | `int64_t` | same C type as `Int` |
| `Int32` | `int32_t` | |
| `UInt` | `uint64_t` | |
| `UInt64` | `uint64_t` | same C type as `UInt` |
| `Float` | `double` | the default float |
| `Float64` | `double` | same C type as `Float` |
| `Float32` | `float` | |
| `Bool` | `bool` | `<stdbool.h>` |
| `String` | `cell_str_t` | length-prefixed view; see section 10.3 |
| `Byte` | `uint8_t` | |

There are exactly eleven primitive names. `Int` and `Int64` are
indistinguishable at the ABI, as are `UInt`/`UInt64` and `Float`/`Float64`;
whether they are distinct *types* in the source language is **designed, not
implemented**, because there is no type representation to distinguish them in.

`String` is a length-prefixed `cell_str_t`, matching `runtime/cell_rt.h`.
Section 10.3 is the ABI table. A literal bound as `arc` is now boxed
(`cell_arc_from_string(cell_string_from_str(...))`); the remaining string gap
is `owned`, which still has no coercion from a literal's view.

**Any other type name silently becomes `void*` with no diagnostic.** `Int8`,
`UInt32`, `Char`, a misspelled `Strng`, and every user-defined struct or enum
all map to `void*`. This is the single largest correctness hole in code
generation: a typo in a type name is not an error, it is an opaque pointer, and
the resulting C then fails on the first field access. Specified:

> `error: unknown type 'Strng'`

`Int8`, `Int16`, `UInt8`, `UInt16`, `UInt32`, and `Char` are **designed, not
implemented**.

### 3.2 Optional types

**Status: parsed, not enforced.**

```cell
Int?
String?
```

`T?` denotes a value that is either a `T` or absent, written as a postfix `?`
on a type name.

The parser builds `TypeExpr.optional` faithfully. Codegen maps it to `void*`
for every `T`, including `Int?`. There is no `none` literal, no `some`
constructor, no unwrap operator, no optional chaining, and no flow-sensitive
narrowing: **an optional value cannot be produced or consumed in Cell today**,
only named in a signature.

The runtime has already chosen the representation (section 10.3): a tagged
struct `{ bool has_value; T value; }`, deliberately not a sentinel, because
every bit pattern of `int64_t` is a legal `Int`. Codegen does not emit it.

**`[T]?` does not parse.** The postfix `?` is only accepted after a bare type
name, never after a `]`. Measured: `shared a: [Int]?` is a parse error. Nested
optionals (`T??`) also do not parse. Both are **designed, not implemented**.

### 3.3 List types

**Status: implemented as a type; there is still no way to use a list value.**

```cell
[Int]
[Byte]
[Int?]
```

`[T]` denotes a homogeneous sequence. Nesting works in the type grammar
(`[[Int]]`, `[Int?]` both parse). There is no indexing operator and no
iteration, so like optionals, a list can be named in a signature and
constructed as an empty literal but not otherwise used.

**CORRECTED 2026-09-07.** This section previously said "Codegen maps every list
to `void*`" and "Codegen does not emit it". Both were false and had been for
some time. Codegen emits `cell_slice_t`
`{ void *ptr; size_t len; size_t cap; }`, one type-erased header for every
element type with `elem_size` passed at each call site, and
`cell emit` produces `int64_t cell_f(cell_slice_t xs);` for
`pub fn f(shared xs: [Byte]) -> Int;`. Measured.

The stale text had a cost worth recording: it was read as saying `[T]` had no
representation *at all*, which made it look like a language gap. It is not. The
LLVM and MLIR backends refused lists only because each returned null for the
type, and at 24 bytes a `cell_slice_t` takes the same indirect path
`cell_string_t` already used. Three lines, not a feature.

What remains genuinely missing is the *use* of a list: no indexing, no
iteration, and only the empty literal `[]` is constructible, because a
non-empty one needs a constant global for its elements that no backend emits
yet.

### 3.4 Result

**Status: designed, not implemented.**

```cell
Result<Int, IoError>
```

`Result<T, E>` is the fallible-return type. **It does not parse.** There is no
`<` `>` handling anywhere in `parseType`; measured, `owned r: Result<Int,
String>` is a parse error at the closing paren of the parameter list. The AST
node `TypeExpr.result` exists and nothing constructs it.

The runtime defines the target layout:

```c
typedef struct cell_result {
    bool ok;
    int32_t error_code;
    cell_value_t value;   /* union of the scalar shapes */
} cell_result_t;
```

One inherited limitation to live with: **`E` is narrowed to an `int32_t` code**
at the C boundary regardless of what `E` is in Cell. A rich error payload would
need a union on the error side too, which this layout does not model. The ok
side does carry its payload inline through `cell_value_t`, so `Result<Int, E>`
needs no allocation; aggregate `T` still travels through `value.ptr`.

Generic types in general (user-written `Vec<T>`, type parameters on `fn`) are
**designed, not implemented**.

### 3.5 Unit

**Status: designed, not implemented.**

The unit type is written `()` and is the type of a function with no `->`
clause. It maps to C `void`. **It does not parse in type position**:
`parseType` requires an identifier, so `-> ()` is a parse error. Omitting the
`->` clause is the only way to express it today, and that works because
`FnDef.return_type` is `?TypeExpr` and codegen emits `void` for `null`. The AST
node `TypeExpr.unit` exists and nothing constructs it.

### 3.6 Struct types

**Status: implemented (layout emission). Field types: not checked.**

See section 8.2. A struct name used in type position falls through
`mapPrimitive` to `void*` (section 3.1), so a struct parameter is currently an
opaque pointer and any field access on it produces invalid C. Measured on
`examples/ownership.cell`: `member reference base type 'void *' is not a
structure or union`.

### 3.7 Enum types

**Status: implemented (C enum emission). Payloads: designed, not implemented.**

See section 8.3.

### 3.8 Ownership-qualified types

**Status: parsed, not enforced.**

An ownership keyword may prefix a type: `shared Int`, `arc String`,
`exclusive Buffer`. The parser builds `TypeExpr.ref` and codegen lowers it by
recursing into the inner type under that ownership, exactly as it does for a
`Param.ownership`. Measured on the current binary: `-> arc String` emits return
type `cell_arc_t` and `(a: shared Int)` emits `int64_t a`. An earlier draft of
this paragraph said every such type became `void*`; that is stale. What remains
unenforced is the canonical-position rule below, not the lowering.

**This creates two spellings for one idea, and the specification picks one.**
`fn f(shared a: Int)` records ownership on `Param.ownership`, while
`fn f(a: shared Int)` records it on `TypeExpr.ref`, and the two produce
different trees and different C. The canonical forms are:

- **Parameters and struct fields: the annotation goes before the name.**
  `fn f(shared a: Int)`, `struct S { owned data: [Byte] }`.
- **Return types and nested positions: the annotation goes on the type**,
  because there is no name to put it before. `-> arc String`, `[shared Buffer]`.
- **Both at once is an error.** `fn f(owned a: shared Int)` parses today and
  means nothing coherent. Specified:

  > `error: parameter 'a' is annotated twice: 'owned' before the name and 'shared' on the type`

Enforcing that choice is **designed, not implemented**.

---

## 4. The ownership model

This is the point of the language. `docs/OWNERSHIP.md` is the normative
statement of the rules a checker must enforce, written as numbered rules with
violating examples and diagnostics. This section defines the vocabulary.

**Status of the whole model: partially enforced.** Annotations are accepted by
the parser and recorded on the AST. `cell check` enforces R2, R3, R5, R8, R14,
R15, and one clause of R10: an `arc` place may not be made **unique**, which is
refused at four positions (an `owned` parameter, an `owned` binding, an
assignment to an `owned` place, and an `owned` struct field). There is no NLL,
and R10's move-into-`arc` is still not checked. The C
backend (`codegen.zig`) inserts drops for an unmoved `owned`/`arc` `let`/`var`
local, function-scoped and conservative on moves; that is R16 partially done,
not R16 complete -- see `docs/OWNERSHIP.md` R16 for exactly which cases still
leak (a value moved on only one path, a struct with owning fields, a `var`
revived after a move). It also inserts R11's `arc` retains, with R11's own
list of what still leaks. See 0.6 and 0.7.

### 4.1 The five annotations

| Annotation | Meaning | Rust analogue | Swift analogue |
|---|---|---|---|
| `owned` | unique owning value, moves on use | `T` (by value) | `consuming` parameter, or a uniquely referenced value type |
| `shared` | immutable borrow, non-owning | `&T` | `borrowing` parameter |
| `exclusive` | mutable borrow, non-owning | `&mut T` | `inout` parameter |
| `arc` | shared ownership by reference count | `Arc<T>` | a `class` instance under ARC |
| `copy` | value semantics, duplicated not moved | `T: Copy` | a trivial `struct` |

#### 4.1.1 `owned`

The callee receives the sole right to the value and is responsible for
destroying it. The caller **may not use the value afterward**; the binding is
dead from the point of the call.

- Callee may: read, mutate, store, return, pass on as `owned`, destroy.
- Caller afterward: nothing. Reading it is a use-after-move (OWNERSHIP.md R2).
- Rust: `fn take(b: Buffer)`. Swift: `func take(_ b: consuming Buffer)`.

`owned` is the **default** when no annotation is written, in every position:
parameters, struct fields, `let`, and `var` (`parseOwnership() orelse .owned`).
This is a significant design commitment inherited from the parser: a bare
`f(x)` is a move.

#### 4.1.2 `shared`

The callee receives read access for the duration of the call and does not own
the value.

- Callee may: read, pass on as `shared`. May not mutate, may not retain beyond
  the call, may not destroy.
- Caller afterward: full use, including moving it, once the borrow ends.
- Rust: `&T`. Swift: `borrowing`.

Any number of `shared` borrows may coexist (OWNERSHIP.md R4).

#### 4.1.3 `exclusive`

The callee receives read and write access for the duration of the call and does
not own the value.

- Callee may: read, mutate in place, pass on as `shared` or `exclusive`. May
  not destroy, may not move out without replacing.
- Caller afterward: full use, and observes the mutations.
- Rust: `&mut T`. Swift: `inout`.

An `exclusive` borrow excludes all other borrows for its duration
(OWNERSHIP.md R5).

#### 4.1.4 `arc`

Ownership is shared among several holders and the value is destroyed when the
last one releases it.

- Callee may: read, retain a copy that outlives the call, return it, store it.
  Mutation through `arc` is **not permitted in this revision** (OWNERSHIP.md
  R9); a mutable-through-`arc` story needs interior mutability, which does not
  exist yet.
- Caller afterward: full use. Its own reference is still valid.
- Rust: `Arc<T>`. Swift: a `class` reference under ARC.

The runtime machinery is real and works: `cell_arc_new`, `cell_arc_clone`, and
`cell_arc_drop` in `runtime/cell_rt.c` do genuine refcount increments and
decrements and call a drop function at zero, and as of `562f116` **the
refcounts are atomic**, with the `_Atomic` confined to the `.c` file behind an
opaque `struct cell_rc_box` so the header still compiles as C++20.

**The C backend now calls them.** Every `arc` binding is a `cell_arc_t`,
whether or not it carries a type annotation; a literal or call result bound as
`arc` is boxed with `cell_arc_from_string` / `cell_arc_from_slice`; an `arc`
place passed to an `arc` parameter, bound to a new `arc` binding, or stored in
a struct field is cloned; and an `arc` place passed to a `shared` parameter is
deliberately not cloned (OWNERSHIP.md R11, safe by R8).
`examples/arc.cell` compiles, links and runs, and prints a strong count.

Six gaps remain and OWNERSHIP.md R11 lists them all with the `leaks` and
AddressSanitizer measurements: an `arc` parameter is never released by a Cell
body, because no parameter is dropped; a struct holding an `arc` field is
never dropped at all; an `arc` value unboxed for a `shared` parameter without
ever being bound drops its handle on the floor; an `arc` local declared inside
a block is never released, because release is function-scoped, which inside a
`while` body is unbounded; reassigning an `arc` `var` leaks the previous box;
and an `owned` String or list **place** bound as `arc` is not boxed, because
R10's move-into-`arc` is unimplemented in the checker and boxing an un-moved
place would double free it.

**Every one of those is a leak, and that is a measurement, not a category.**
Two earlier drafts here made the categorical claim and review falsified both:
the first covered a returned `arc` field handed out unretained and a shadowed
`arc` local released twice; the second, written after a re-derivation that
searched only return-position PLACES, covered three more on VALUE paths (an
`arc` place flowing out of an `if` branch or a `match` arm, and an `arc` place
passed to an `owned` parameter), and a third round found two more: an `arc`
match-arm binding returned from a BLOCK arm body, and `let owned ys: [Int] = xs`.
**Seven** in total. All seven are fixed, five by a retain and two by R10
refusing the conversion, and all seven carry tests. R11 names them
and records which positions the third search actually covered, places and
values alike. Read the list as what running programs has found, not as a proof
that nothing dangles.

R10's `arc`-cannot-be-made-unique clause is now enforced by `borrowck.zig` at
all four positions where it arises, which makes it the first clause of R10 to
land; move-into-`arc` is still designed only. Every `arc`-to-`arc` use stays
legal: the refusal is scoped to making an `arc` place unique, not to `arc`.

The LLVM and MLIR backends refuse `arc` outright and emit nothing.

#### 4.1.5 `copy`

The value has copy semantics: passing it duplicates it, and the source stays
live.

- Callee may: do anything with its copy.
- Caller afterward: full use. Nothing was moved.
- Rust: a `Copy` type. Swift: a trivial `struct`.

`copy` is a property the programmer asserts here, not one the compiler derives
from the type. Deriving copyability, and rejecting `copy` on a type that owns a
resource, is **designed, not implemented**, and until it exists `copy` on a
resource-owning type is an unchecked route to a double free.

### 4.2 Ownership at call sites

**Status: parsed, then discarded.**

An ownership keyword may prefix a call argument:

```cell
grow(exclusive buf, shared 16)
take(owned buf)
```

`parsePrimary` consumes the keyword, parses the operand, and returns the
operand's kind with only the *span* widened to cover the keyword. **The
ownership is thrown away** before the argument node is built, so nothing
records that the caller asked for an exclusive borrow and nothing can check it
against the parameter. Measured: the prefix is dropped from the AST, and the
call emits `cell_grow(&buf, 16)` from the callee signature (mangling plus the
exclusive address-of).

This specification keeps the call-site annotation and makes it meaningful: an
explicit annotation must match the parameter's annotation (OWNERSHIP.md R15),
and omitting it is allowed and inferred from the callee's signature. The
`&x` / `&mut x` forms (section 6.5) are the alternative spelling.

### 4.3 What ownership does today

`cell check` enforces R2, R3, R5, R8, R14, R15, and R10's
`arc`-cannot-be-made-unique clause (at all four positions) through
`src/cell/borrowck.zig`. Codegen lowers `shared` aggregates
to `const T *`, `exclusive` aggregates to `T *`, and `arc` parameters to
`cell_arc_t`. It boxes a literal or call result bound as `arc`, inserts
`cell_arc_clone` at OWNERSHIP.md R11's three retain-a-place sites, and emits
`cell_arc_drop` at scope exit, so `examples/arc.cell` emit compiles, links and
runs. R11's remaining gaps are listed there and in 4.1.4.

---

## 5. Expressions: precedence and associativity

### 5.1 Precedence table

**Status: implemented.** This is exactly `Parser.binaryPrec`, verified by
reading the parenthesization in emitted C.

| Level | Operators | Associativity |
|---|---|---|
| 6 (tightest binary) | `*` `/` | left |
| 5 | `+` `-` | left |
| 4 | `<` `<=` `>` `>=` | left |
| 3 | `==` `!=` | left |
| 2 | `&&` | left |
| 1 (loosest) | `\|\|` | left |

Unary operators (`-` `!` `&` `&mut` `&exclusive`) bind tighter than every
binary operator. Postfix suffixes (`.field` and `(args)`) bind tightest of all
and chain freely (section 6.4).

Measured: `a + b * c - a / b == c && a < b || !c` emits

```c
(((((a + (b * c)) - (a / b)) == c) && (a < b)) || !c)
```

and `a - b - a` emits `((a - b) - a)`, confirming left associativity.

All comparison operators are at the same level and left-associative, so
`a < b < c` parses as `(a < b) < c` rather than being rejected by the parser.
The working-tree type checker now rejects it with `operator '<' cannot be
applied to Bool and Int`, which is the specified outcome delivered by a type
rule rather than a parser special case (see 0.5 and
`examples/rejected/chained_comparison.cell`).

Codegen writes fully parenthesized C for every binary expression, so C's own
precedence never changes the meaning of an emitted expression.

### 5.2 Not in the grammar

**Status: designed, not implemented.** Assignment is a statement, not an
expression, so there is no assignment operator level. There is no ternary, no
range, no `as` cast, no `%`, no bitwise or shift level, no null-coalescing, and
no pipeline operator.

---

## 6. Expressions

### 6.1 Literals

**Status: implemented.** Integer, float, string, and boolean literals are
primary expressions (sections 2.6 to 2.9).

### 6.2 Identifiers

**Status: implemented.** A bare identifier is a primary expression. Name
resolution is **designed, not implemented** in committed `src/`: an undefined
identifier is emitted into C verbatim and becomes a C error, or worse, an
implicit declaration. It is implemented in the working tree, which reports
`unknown identifier 'print'`; see 0.5.

### 6.3 Field access

**Status: implemented (parse and emit).**

```cell
buf.len
a.b.c
```

`Expr.field` carries a `base` expression and a field `name`, so `a.b.c` is a
real nested tree rather than a flattened string. Codegen emits `base.name`,
which is correct C whenever the base has a struct type. `ast.rootName` walks a
field chain down to its base binding and is what makes field assignment
checkable (section 7.3).

Field *resolution* is **designed, not implemented**: no check that the field
exists, and no field type. Because a struct parameter maps to `void*`
(section 3.6), field access on one still produces invalid C today.

### 6.4 Calls and postfix chains

**Status: implemented for named calls. Method dispatch: designed, not implemented.**

```cell
add(40, 2)
xs.len()
a.b(c).d
```

`parsePostfix` applies any number of `.field` and `(args)` suffixes to a
primary expression, so **method-call syntax parses** and chains arbitrarily.
Measured: `xs.len()` parses, where an earlier revision rejected it.

Named calls are mangled at the call site: `add(40, 2)` emits `cell_add(40, 2)`
when `add` is a Cell function (section 10.2). There is no method *dispatch*:
`xs.len()` builds a call whose callee is the field expression `xs.len`.
Methods, `impl` blocks, and receiver resolution are **designed, not
implemented**.

Trailing commas in an argument list are not accepted.

Inside call arguments the struct-literal restriction is lifted
(`no_struct_lit` is cleared), so `f(Point { x: 1.0 })` parses even in a
condition.

### 6.5 Unary operators

**Borrow sigils, and the three spellings of a unique borrow.** `&x` is an
alternative spelling of `shared x`, and `&mut x`, `&var x` and `&exclusive x`
are all alternative spellings of `exclusive x`. The parser builds one node per
mode, so the four unique-borrow forms are indistinguishable after parsing.
`&var` is the CELL v2.0 spelling, admitted by the union recorded in 0.8.

At a **call site**, a keyword prefix wins over an inner sigil: `f(owned &buf)`
passes `buf` as `owned`, because the written keyword is the mode and the sigil
is redundant with it. This differs from a **parameter**, where mixing an
annotation with an ownership-qualified type (`fn f(owned a: shared Int)`) is
specified as an error in 3.8, because those two annotations land in different
places and produce different C, so there is no single coherent meaning to pick.


**Status: `-` and `!` implemented. Reference operators parsed, then collapsed.**

```cell
-x            // negation
!x            // logical not
&x            // shared borrow
&mut x        // exclusive borrow
&exclusive x  // exclusive borrow, long spelling
```

`&mut` and `&exclusive` are exact synonyms in the parser. `&x` builds
`UnaryOp.ref_shared` and the other two build `UnaryOp.ref_exclusive`, so the
distinction survives into the AST, but **codegen emits a bare `&` for all
three**, so it does not survive into C. Measured: `g(&a)`, `h(&mut a)`, and
`k(&exclusive a)` all emit `&a`.

There is no dereference operator. Address-of is emitted even when the operand
is already a pointer.

### 6.6 Parenthesized expressions

**Status: implemented.** `( expr )` groups, and clears the struct-literal
restriction inside. There is no tuple: `(a, b)` does not parse, and `()` does
not parse as an expression.

### 6.7 Struct literals

**Status: implemented (parse and emit).**

```cell
Point { x: 1.0, y: 2.0 }
Point { x, y }              // shorthand for { x: x, y: y }
```

`Expr.struct_lit` carries the type name and a slice of `FieldInit`, each with
its own name, value expression, and span. Field shorthand is supported: a bare
`x` with no `:` expands to `x: x`.

Codegen lowers a literal to a C compound literal, for example
`(cell_Point){ .x = 1.0, .y = 2.0 }`. Measured on `examples/hello.cell`.

**The struct-literal ambiguity is correctly resolved.** A parser flag,
`no_struct_lit`, is set while parsing an `if` condition or a `match` scrutinee
and cleared inside parentheses, brackets, and call arguments. That is exactly
Rust's rule, and it means `if c { ... }` now parses, where an earlier revision
misread `c { ... }` as a struct literal and failed. Measured. Where a struct
literal really is wanted in a condition, parentheses restore it:
`if (Point { x: 1.0 }.x > 0.0) { ... }`.

### 6.8 List literals

**Status: implemented (parse and emit).**

```cell
[]
[1, 2, 3]
```

`Expr.list_lit` carries the element expressions. An empty list emits
`cell_slice_empty()`. A populated list lowers to a GNU statement expression
that `cell_slice_alloc`s a buffer and `cell_slice_push`es each element.
There is no indexing operator (section 6.11).

### 6.9 `if` expressions

**Status: implemented.** The parser is complete; codegen emits C `if` / `else`.

```cell
if cond { ... }
if cond { ... } else { ... }
if a { ... } else if b { ... } else { ... }
```

`parseIf` records the condition, the then-block as a block expression, and an
optional else, and recurses on `else if` so a chain is a nested `if_expr`. The
condition is parsed with the struct-literal restriction on (section 6.7). All
three forms parse. Measured.

Statement-position `if` lowers to C `if` / `else`, including `else if` chains.
A function whose whole body is `if (c) { return 1 } else { return 2 }` emits
that control flow, not a placeholder. Value-producing `if` lowers by assigning
both arms into a temporary. Measured on `examples/control_flow.cell`.

### 6.10 Block expressions

**Status: implemented (parse and emit).**

A brace-delimited block is a primary expression, so `{ ... }` may appear
wherever an expression may. `Expr.block` carries the statements. Codegen
lowers a block to a braced C compound statement, or to a statement expression
when the block is used as a value.

This is what makes the `while` trap in section 2.5 possible, and it is worth
restating: because a block is an expression statement, a syntactically
loop-shaped program parses and does nothing.

### 6.11 Indexing

**Status: designed, not implemented.** `a[0]` does not parse in expression
position; `[` only begins a list literal, and `parsePostfix` has no bracket
suffix.

---

## 7. Statements

### 7.1 Statement termination

**Status: implemented.** Semicolons are **optional everywhere**. Every
statement form ends with `_ = self.match(.semicolon)`, which consumes a
semicolon if present and is content without one. Both of these are the same
program:

```cell
let copy a = 1
let copy b = 2
```

```cell
let copy a = 1; let copy b = 2;
```

### 7.2 `let` and `var` bindings

**Status: implemented.**

```
let_stmt = ("let" | "var") ["mut"] [ownership] identifier [":" type] ["=" expr] [";"]
```

```cell
let owned buf = Buffer { data: [], len: 0 }
let mut copy n: Int = 0
var count = 0
```

- `let` is immutable by default. `let mut` makes it mutable.
- `var` is mutable. **`var mut x` is a parse error**, because `var` short
  circuits the mutability check before `mut` can be consumed. Measured. Writing
  `mut` after `var` is specified as redundant and should be a warning, not an
  error; that is **designed, not implemented**.
- Ownership defaults to `owned` when omitted.
- The type annotation is optional. Type **inference is designed, not
  implemented** in the typechecker: an unannotated `3.5` is still accepted as
  if it were an integer. Codegen picks the C type from the initializer when it
  can. Measured: `let owned xs = [1, 2, 3]` emits `cell_slice_t`. An
  unannotated binding with no typed initializer still emits `int64_t`.
- The initializer is optional. A `let` with no initializer emits an
  uninitialized C declaration; definite-assignment analysis is **designed, not
  implemented**.

### 7.3 Assignment

**Status: implemented.** Typecheck checks the value's type against the target.
Borrowck owns R14 (immutable assignment).

```
assign_stmt = expr "=" expr [";"]
```

```cell
n = 2
buf.len = new_len
```

The parser parses the left side as a full expression and then looks for `=`,
which removes the backtracking an earlier revision needed and makes `x = e` and
`x.y = e` one code path. `Stmt.assign.target` is therefore an `Expr`, not a
string.

R14 lives in `src/cell/borrowck.zig`. It names the place and notes the `let`:

```
examples/rejected/immutable_assign.cell:9:5: error: cannot assign to immutable binding 'x'
```

Typecheck does **not** also report R14; a same-type write to an immutable
binding is a typecheck-clean borrow error. A type mismatch on assignment is
still a typecheck error. Measured, with a real path, line, and column. Three
behaviors worth stating precisely:

1. **Field assignment is checked**, through the root binding. Assigning to
   `b.len` where `b` is an immutable `let` is an error. Measured. An earlier
   revision missed this because the target was a joined string.
2. **Parameter mutability follows the ownership mode**: `exclusive` and `owned`
   parameters are mutable, and `shared`, `arc`, and `copy` parameters are not.
   Measured for all three of the immutable modes. For `arc` this agrees with
   OWNERSHIP.md R9, though by derivation rather than by an explicit rule.
3. **The symbol table was module-wide and never scoped**, so a `let x` in one
   function was visible to an assignment in a *different* function. **Fixed in
   `8dd5673`** (see 0.5): the same probe now reports `unknown identifier 'x'`.
   Section 12 tags block scoping as implemented.

There is no check that the target is assignable at all: assigning to a literal
or a call result is accepted and emits nonsense C. Compound assignment (`+=`)
and indexed assignment (`a[0] = x`) are **designed, not implemented**.

### 7.4 `return`

**Status: implemented.**

```cell
return
return a + b
```

The value is optional; the parser stops looking for one at `;` or `}`.
Typecheck reports a missing return and a return-type mismatch. Borrowck reports
R8 at the returned expression when the declared return is a `shared` or
`exclusive` borrow. Codegen maps a declared `arc` return to `cell_arc_t`, and
retains every returned `arc` place except a parameter returned directly:
a LOCAL, so the scope drop cannot free it before the caller sees it
(OWNERSHIP.md R11 release rule 2), and a FIELD, so the caller's eventual
release does not free a box the record still points at. A parameter is the one
reference the frame received pre-retained and hands straight back (R11 rule 3).

### 7.5 Expression statements

**Status: implemented.** Any expression may stand as a statement. There is no
unused-result diagnostic, which is half of the `while` trap in section 2.5.

### 7.6 Loops

**Status: implemented (`while`). `for` and `loop` are designed, not
implemented.**

```
while_stmt = "while" expr_no_struct_lit block
```

```cell
var i = 0
while i < n {
    i = i + 1
}
```

Both `while c { }` and `while (c) { }` are accepted, the second because a
parenthesized expression is already an expression. The condition uses the
no-struct-literal expression form for the same reason `if` and `match` do:
otherwise `while c { ... }` would read `c { ... }` as a struct literal and
swallow the body. The condition must be `Bool`.

A `while` is a **statement, not an expression**, unlike `if`. An `if` produces
a value from its branches; a loop produces nothing, and modelling it as an
expression would force a unit value this language cannot name (section 3.5:
`()` does not parse in type position).

`for`, `loop`, and iteration over a collection remain designed. There is no
iteration protocol, no range value, and no indexing operator (section 3.3), so
`for` needs all three before it needs syntax.

**Loops interact with ownership, and that interaction is a rule, not a
detail.** See `docs/OWNERSHIP.md` R2.a: a place declared outside a loop and
moved inside it is rejected, because the next iteration would use it after the
move. `examples/rejected/move_in_loop.cell` is the worked case.

### 7.7 `break` and `continue`

**Status: implemented.**

```
break_stmt    = "break"
continue_stmt = "continue"
```

Both apply to the innermost enclosing `while`. Using either outside a loop is
an error reported by the typechecker, so the diagnostic points at Cell source
rather than at emitted C:

> `err: 'break' is only valid inside a loop`

Neither carries a value and neither takes a label. Labelled loops are not
designed.

## 8. Items

An item is a top-level declaration. `parseModule` reads items until EOF; a
module is a flat list with no ordering requirement and no forward-declaration
rule. Every item carries a span, which `cell dump` prints.

### 8.1 Functions

**Status: implemented (signature and body). Bodyless form: implemented.**

```
fn_item = ["pub"] "fn" ident "(" [params] ")" ["->" type] (block | ";")
params  = param ("," param)*
param   = [ownership] ident ":" type
```

```cell
pub fn add(shared a: Int, shared b: Int) -> Int {
    return a + b
}

pub fn host_write(shared msg: String) -> Int;
```

- Each parameter needs a type. There are no default values, no variadics, no
  named arguments at the call site, and no generic parameters.
- Trailing commas in the parameter list are not accepted.
- Omitting `->` means the return type is unit, emitted as C `void`.
- A function with `;` instead of a block is a **declaration**: it emits a C
  prototype and no definition. This is the mechanism behind body files
  (section 1.2) and behind the prelude's host intrinsics, and it is the only
  form whose emitted C reliably compiles (section 10.2).
- Nested functions, closures, and methods are **designed, not implemented**.

### 8.2 Structs

**Status: implemented (layout emission).**

```
struct_item = ["pub"] "struct" ident "{" field* "}"
field       = [ownership] ident ":" type [","] [";"]
```

```cell
pub struct Buffer {
    owned data: [Byte]
    copy len: Int
}
```

Field separators are fully optional and interchangeable: comma, semicolon, or
nothing all work, and mixing them within one struct parses. Standardizing on
the comma is **designed, not implemented**.

Emits `typedef struct cell_Buffer { ... } cell_Buffer;` with each field's
ownership as a trailing comment. Field ownership is otherwise ignored. There
are no methods, no `impl` blocks, no generic parameters, no tuple structs, and
no visibility on individual fields.

### 8.3 Enums

**Status: implemented (C enum emission). Payloads: designed, not implemented.**

```
enum_item = ["pub"] "enum" ident "{" ident ("," ident)* [","] "}"
```

```cell
pub enum Color { Red, Green, Blue }
```

Emits `typedef enum cell_Color { cell_Color_Red, ... } cell_Color;`.

Two gaps:

- **Variants cannot carry data.** Measured: `enum Opt { None, Some(Int) }` is a
  parse error at `(`. `EnumDef.variants` is `[][]const u8`, a list of bare
  names, so the AST cannot represent a payload at all. Since algebraic data
  types are one of the three things Cell claims to take from Rust, this is the
  second largest gap after iteration, and it is the reason match patterns have
  no subpatterns (section 9).
- **The emitted width is wrong.** `runtime/cell_rt.h` requires a payload-free
  enum to lower to a distinct integer type of width `int32_t`; a bare
  `typedef enum` has implementation-defined width. An explicit integer typedef
  plus constants is **designed, not implemented**.

Explicit discriminant values are also **designed, not implemented**.

### 8.4 `use` declarations

**Status: parsed, emitted as a comment.**

```
use_item = ["pub"] "use" path [";"]
path     = ident ("." ident)*
```

```cell
use std.io
use std.mem.alloc
```

The path is recorded as a flattened string and emitted as `// use std.io`.
There is **no module resolution, no import, and no name binding**: nothing a
`use` names becomes available. `pub use` parses and the `pub` is discarded
(`Item.use_decl` is just a string). Module resolution is **designed, not
implemented**.

### 8.5 `pub` and visibility

**Status: parsed, minimally used.**

`pub` is recorded on functions, structs, and enums, and dropped on `use`. Its
only effect is that a `pub fn` emits a `// export` comment above its C
definition. Nothing is hidden: a non-`pub` function still emits an externally
visible C function with the same linkage. Real visibility, and `static` linkage
for non-`pub` items, are **designed, not implemented**.

---

## 9. Pattern matching

**Status: implemented (parse and emit).** The parser is real; codegen lowers
`match` to a scrutinee temporary plus an if/else chain. Exhaustiveness is not
checked; a missing catch-all arm becomes `cell_panic`.

```cell
match value {
    Color.Red => 0,
    Green     => 1,
    0         => 2,
    -1        => 3,
    "text"    => 4,
    other     => 5,
    _         => 6,
}
```

`parseMatch` records a scrutinee and a slice of `MatchArm`, each with a
structured `Pattern` and a body expression. The scrutinee is parsed with the
struct-literal restriction on (section 6.7), so `match c { ... }` works.

### 9.0 Match guards

**Status: implemented, except on a binding pattern.**

```
arm = pattern [ "if" expr ] "=>" expr
```

```cell
match c {
    Color.Green if n > 5 => 7,
    Color.Green => 1,
    _ => 0,
}
```

A guard is an extra condition the arm must satisfy on top of matching its
pattern. It reuses `if` and `=>` and needs no new token. The guard must be
`Bool`, and it is evaluated **only when the pattern matched**, so a guard may
call a function without that call happening on every arm.

**A guarded arm is never a catch-all**, however catch-all its pattern looks.
`_ if c` can fail, so a `match` whose only wildcard arm is guarded still emits
the non-exhaustive panic (section 11) rather than falling through with a
made-up result.

**A guard on a binding pattern (`m if m > 3`) is rejected**, with
`a guard on a binding pattern is not implemented yet`. The C backend declares
the arm's binding inside the arm body, where a guard in the condition cannot
see it. Refusing is deliberate: the alternative would emit C that either fails
to compile or silently reads a different variable.

### 9.1 The implemented pattern grammar

```ebnf
pattern = "_"                       (* wildcard *)
        | ident                     (* binding, or bare enum variant *)
        | ident "." ident           (* qualified enum variant *)
        | ["-"] int
        | ["-"] float
        | string
        | "true" | "false"
```

`Pattern.Kind` has exactly seven cases: `wildcard`, `binding`, `enum_variant`,
`int`, `float`, `string`, `bool`.

Two parser behaviors are worth knowing because they are lexical heuristics
rather than semantic decisions, and both are specified as things a real
resolver should replace:

1. **`_` is recognized by comparing the lexeme.** `_` is an ordinary identifier
   everywhere else (section 2.3).
2. **A bare identifier is a variant if its first letter is uppercase, and a
   binding otherwise.** So `Green` is an enum variant and `other` binds. That
   is a naming convention promoted to a parse rule, decided before any name is
   resolved. It means a lowercase variant can never be matched by its bare
   name, and an uppercase binding is impossible. The qualified form
   `Color.Red` is unambiguous and is the form to prefer. Resolving this by
   looking the name up instead is **designed, not implemented**.

A negative numeric pattern is folded in the parser (`-1` becomes the literal
`-1`) because a pattern is not an expression and cannot hold a unary operator.

### 9.2 What is missing

**Designed, not implemented:**

- **Payload patterns.** `Some(x)` does not parse, because enum variants carry
  no payload (section 8.3). `Pattern.Kind` has no case for subpatterns, so
  adding them means extending the type, not filling a field.
- **Struct patterns** (`Point { x, y }`), tuple patterns, and slice patterns.
- **Or-patterns.** There is no `|` operator in the lexer (section 2.10).
- **Guards** (`if cond` after a pattern).
- **Range patterns.**
- **Exhaustiveness checking.** Nothing verifies that the arms cover the
  scrutinee's type or that a `_` arm exists. Nothing warns about an unreachable
  arm. This needs a type representation.
- **Binding ownership.** A binding pattern should take the scrutinee's
  ownership, so matching on an `owned` value moves it into the arm
  (OWNERSHIP.md R7). Nothing enforces that.
- **Code generation.** Codegen lowers `match` to a scrutinee temporary plus an
  if/else chain. An unmatched value calls `cell_panic`. Payload patterns and
  exhaustiveness checking are still missing, so this is control-flow lowering,
  not a complete match implementation.

`if let` and `while let` are not part of this specification.

---

## 10. The C ABI contract

Cell is C-ABI-first: the C mapping is the language's interoperability story,
not an implementation detail.

### 10.1 Emitted translation unit

**Status: implemented (shape).**

`cell emit <file>` writes one C translation unit to stdout: a provenance
comment, `#include "cell_rt.h"`, then one C declaration per item in source
order. That include is what makes `cell_str_t`, `cell_slice_t`, and
`cell_arc_t` available to generated code.

It does not emit a header, an include guard, or an `extern "C"` block.
Splitting emission into a `.h` and a `.c`, which is what a header-shaped
language needs, is **designed, not implemented**.

A zero-parameter function emits `f(void)`, matching the runtime header.
Measured.

### 10.2 Name mangling

**Status: implemented for definitions and named call sites.**

The mangling scheme is `cell_<name>`, with no encoding of parameter types,
arity, ownership, or module path. Consequences: **there is no overloading**, a
Cell module cannot define two functions with the same name, and a Cell symbol
collides with any C symbol literally named `cell_<name>`.

Applied consistently to definitions and to named calls:

| Cell | C symbol |
|---|---|
| `fn add` | `cell_add` |
| `struct Buffer` | `cell_Buffer` (both tag and typedef) |
| `enum Color` | `cell_Color` |
| variant `Red` of `Color` | `cell_Color_Red` |

A call to `add` emits `cell_add(...)`. Bodyless declarations of runtime
intrinsics (`print`, `print_int`, ...) keep the runtime's own symbol.

**Measured, on a binary built with `-Dswift=false`, over all fourteen files in
`examples/` rather than a chosen few.** Compilation and linking are separate
claims and are reported separately, because a file that compiles may still
have no `main` or may call a declaration nothing defines.

`cc -std=c11 -Wall -Wextra -c`: **all fourteen compile.** No exceptions, and
that includes `arc.cell`, which was the last one that did not.

Link against `runtime/cell_rt.c` and run: **six of the fourteen**, namely
`hello` (42), `backends` (24), `loops` (55), `while_is_now_a_loop` (10),
`ownership` and `borrows` (both silent, exit 0). `arc.cell` links and runs
too, printing 13, but needs one extra source: `examples/arc_host.c` defines
its two bodyless declarations, and `tools/check.sh` supplies it through
`run_c_host`. The remaining seven (`bindings`, `control_flow`, `declarations`,
`expressions`, `pattern_matching`, `primitives`, `structs_enums`) do not link,
and all seven fail for the same single reason, measured rather than assumed:
none declares a `pub fn main()` with a body, so `emitEntryPoint` writes no C
`main` and the link stops at `undefined symbol: _main`. Nothing about their
emitted code is rejected.

A module-qualified mangling (`cell_<module>_<name>`) is **designed, not
implemented**.

### 10.3 The value model

**Status: implemented for the types the compiler can name.**

`runtime/cell_rt.h` carries an authoritative reference block specifying how
every Cell type lowers to C. **This specification adopts that block as the
target ABI.** Codegen now emits `#include "cell_rt.h"` and follows that mapping
for primitives, strings, slices, optionals, structs, payload-free enums, and
`arc`.

| Cell | Specified C | What codegen emits today |
|---|---|---|
| primitives (section 3.1) | by value, in every ownership mode | matches |
| `shared String` | `cell_str_t` (borrowed `ptr`+`len` view) | `cell_str_t` |
| `owned String` | `cell_string_t` (heap `ptr`+`len`+`cap`, callee frees) | `cell_string_t` |
| `exclusive String` | `cell_string_t*` | `cell_string_t *` |
| `arc String` | `cell_arc_t` over a heap `cell_string_t` | `cell_arc_t` everywhere, including a `let` with no annotation; a literal is boxed with `cell_arc_from_string(cell_string_from_str(...))` |
| `copy String` | `cell_string_t` from `cell_string_clone` | `cell_string_t` (no clone call) |
| `[T]` | `cell_slice_t { ptr, len, cap }`, type-erased, `elem_size` at each call site | `cell_slice_t` |
| `T?` | tagged `{ bool has_value; T value; }` | `CELL_DEFINE_OPTIONAL` instance |
| `Result<T, E>` | `cell_result_t { ok, error_code, cell_value_t value }` | does not parse |
| struct | C struct, same field order, each field lowered by its own ownership | `cell_<Name>` |
| payload-free enum | distinct integer type of width `int32_t` | `typedef int32_t cell_<Name>` |

Three consequences of that model that Cell must live with, all inherited from
the runtime rather than chosen here:

1. **`String` is a length-prefixed slice, not a NUL-terminated `char*`.** That
   makes substrings, embedded NUL bytes, and Zig or Swift interop free, and it
   costs a copy whenever a Cell string is handed to a C function that wants
   `const char*`. It also means `owned String` and `shared String` are
   distinguishable at the ABI, which the old `const char*` mapping could not
   express. Buffers this runtime allocates happen to be NUL-terminated one byte
   past `len`, and no consumer may rely on that for a string it did not
   allocate there.
2. **`[T]` is one type-erased header, not a family of generated types.** C11
   has no generics, so every runtime helper that does element arithmetic takes
   `elem_size` explicitly.
3. **`T?` is tagged, never a sentinel**, because every bit pattern of `int64_t`
   is a legal `Int`. The cost is padding: `cell_opt_i64_t` is 16 bytes where a
   sentinel would have been 8. The benefit is one uniform lowering rule that
   never has to ask whether `T` has a spare value.

### 10.4 Ownership at the boundary

**Status: lowered for all five modes; retain/release enforced for `arc` in the
C backend only.** `shared` / `exclusive` / `owned` / `copy` lower as
specified. `arc` is `cell_arc_t` everywhere, literals and call results are
boxed, and retain/release is inserted per OWNERSHIP.md R11, whose own text
lists the three cases that still leak.

`runtime/cell_rt.h` section 7 fixes the lowering for each mode, and this
specification adopts it:

| Mode | C form | Caller obligation | Callee obligation |
|---|---|---|---|
| `copy` | by value | nothing, the value is duplicated | owns an independent bitwise copy |
| `shared` | primitives by value, aggregates as `const T*`, String and lists by value as views | keeps the value alive for the call | must not free, must not mutate, must not retain past the call |
| `exclusive` | `T*` | grants sole access for the call | may mutate, must not free, must leave it valid |
| `owned` | by value, caller relinquishes | must not use the value again | responsible for the eventual free |
| `arc` | `cell_arc_t` by value | has already retained | releases when done, or clones to keep it |

Note the deliberate exception: **primitives stay by value in every mode**,
including `shared`. That is forced by the language itself, because
`examples/hello.cell` declares `add(shared a: Int, shared b: Int)` with the
body `a + b`, and a `shared` primitive lowered to a pointer would stop that
expression compiling.

Today, `shared` aggregates emit `const T *`, `exclusive` aggregates emit
`T *`, and `owned` / `copy` emit the by-value C type from section 3.1.
`arc` is `cell_arc_t` in every position, and `let arc label = "session"`
boxes the literal, so passing it to an `arc` parameter compiles and retains.
An `arc` place passed to a `shared String` parameter is unboxed to a view with
`cell_string_as_str((const cell_string_t *)x.ptr)` and is not retained, which
is R11's one deliberate non-retain.

### 10.5 Return values

**Status: implemented (mapping). Ownership of returns: designed.**

The return type maps by section 3.1, and no `->` clause means `void`. The
rule for `arc` is implemented in the C backend: a returned `arc` value is
returned **already retained**, so the caller must release it, and a returned
`arc` local or FIELD is cloned into the return temporary to make that true, in
the face of the scope drop for a local and of the caller's own release for a
field. Only a parameter returned directly is handed back uncloned. Still designed, not implemented: a returned `owned` value
transfers ownership to the caller, and returning a `shared` or `exclusive`
borrow requires
a lifetime story this revision does not have and therefore forbids
(OWNERSHIP.md R8).

### 10.6 Calling Cell from Zig, C, C++, and Swift

**Status: designed, not implemented** for anything generated. The *runtime* is
real and cross-language by construction: `runtime/cell_rt.h` has an
`extern "C"` block, avoids compound literals, `_Atomic`, and anonymous unions
specifically so it compiles as C11, as C++20, and through Swift's importer, and
`src/main.zig` links and calls `cell_rt_version`, `cell_cxx_probe`, and
`cell_swift_probe` as externs. Measured: `cell version` prints
`cell-rt 0.1.0 (c11)` and `cxx probe: 11`.

But there is no generated header for a Cell module, so a C or Swift caller has
nothing to include and no prototype to import. Producing one is the first piece
of work the C-ABI-first claim actually requires.

### 10.7 Host intrinsics

**Status: implemented for the symbols codegen knows.**

The runtime provides `cell_print`, `cell_println`, `cell_print_int`,
`cell_assert`, `cell_assert_msg`, and `cell_panic`, plus the arena, slice,
string, optional, and arc helpers. `stdlib/prelude.cell` declares Cell names
that mangle onto several of them.

Generated code can call them. `String` is `cell_str_t` (section 10.3), so a
call to `print("hi")` emits `cell_print(cell_str_from_parts("hi", 2))`.
`examples/hello.cell` reaches `cell_print_int`. Arena, slice, and arc helpers
are still not inserted automatically.

### 10.8 Panics

**Status: implemented for match lowering.** There is no `panic` keyword and no
unwinding. `cell_panic` exists and aborts after writing to stderr. A `match`
without a catch-all arm emits `cell_panic("non-exhaustive match in <fn>")`.
There is no assertion lowering beyond a direct call to the `assert` intrinsic.

---

## 11. Diagnostics

**Status: implemented for check diagnostics. Parser diagnostics are recorded
but not wired to the CLI.**

`src/cell/diag.zig` is a real diagnostic system. `Bag.init` takes the path
and an optional source buffer; `err`, `warning`, and `note` push a `Diagnostic`
carrying an `ast.Span`; and `render` prints the standard shape plus the source
line and a caret:

```
path:line:column: error: message
```

The parser records its failure: `Parser.last_error` holds a span and a message,
and `reportInto` pushes it into a bag. A test parses deliberately broken source
and asserts the full rendered text including the caret line, so the position the
parser records and the position the renderer prints are checked against each
other.

Three gaps remain, and the first is the one a user actually hits:

1. **The CLI does not surface parse diagnostics.** `root.compile` returns the
   bare `error.UnexpectedToken` and `main` lets it escape. Measured: a syntax
   error prints the Zig error name and a Zig stack trace pointing into
   `parser.zig`, with no source location and no caret. The recorded message and
   span exist and nothing reads them. Wiring `reportInto` into `root.compile`
   is a small change and is the highest-value remaining diagnostic work.
2. **Check diagnostics do reach the user**, with path, line, column, the source
   line, and a caret. Measured. They are printed through `Bag.printAll` /
   `Bag.render` from `root.check`.
3. **There is no recovery.** The first parse error aborts. Reporting several
   errors from one file needs a resynchronization strategy that does not exist.

---

## 12. Status index

Every construct in this specification, with its status. The counts in section
0.2 are the counts of this table. Where the parser implements something that
codegen does not lower, the row is **parsed, not enforced** and a separate row
records the missing lowering.

### Lexical

| Construct | Status |
|---|---|
| Line comment `//` | implemented |
| Block comment `/* */`, non-nesting | implemented |
| Doc comment `///` semantics | designed, not implemented |
| ASCII identifiers | implemented |
| `_` reserved as a wildcard outside patterns | designed, not implemented |
| Unicode identifiers | designed, not implemented |
| Keywords (19) | implemented |
| Reserved words (`while`, `for`, ...) | designed, not implemented |
| Decimal integer literal | implemented |
| Hex / binary / octal literal | designed, not implemented |
| Underscore digit separator | designed, not implemented |
| Decimal float literal | implemented |
| Exponent float literal | designed, not implemented |
| String literal lexing | implemented |
| String escape processing | designed, not implemented |
| Unterminated string diagnostic | designed, not implemented |
| Multi-line / raw / interpolated strings | designed, not implemented |
| Boolean literals | implemented |
| Operator and punctuation set | implemented |
| `%`, bitwise, shift, compound assignment | designed, not implemented |
| Token byte spans and line/column | implemented |

### Types

| Construct | Status |
|---|---|
| The 11 primitives and their C mapping | implemented |
| Unknown type name rejection | designed, not implemented |
| Additional integer widths (`Int8`, `UInt32`, ...) | designed, not implemented |
| `T?` optional syntax | parsed, not enforced |
| Optional lowering to the tagged struct | designed, not implemented |
| Optional construction and unwrapping | designed, not implemented |
| `[T]?` | designed, not implemented |
| `[T]` list syntax | parsed, not enforced |
| List lowering to `cell_slice_t` | designed, not implemented |
| `Result<T, E>` | designed, not implemented |
| Generic types | designed, not implemented |
| Unit type `()` in type position | designed, not implemented |
| Implicit unit from an omitted `->` | implemented |
| Struct types in type position | parsed, not enforced |
| Enum types | implemented |
| Enum lowering at `int32_t` width | implemented |
| Ownership-qualified types (`shared T`) | parsed, not enforced |
| Canonical annotation position rule | designed, not implemented |

### Ownership

| Construct | Status |
|---|---|
| `owned` annotation | implemented |
| `shared` annotation | implemented |
| `exclusive` annotation | implemented |
| `arc` annotation | implemented in the C backend (retain, boxing, unbox, and scope release); parsed only for LLVM and MLIR, which refuse `arc` |
| `copy` annotation | implemented |
| Default ownership is `owned` | implemented |
| Call-site ownership prefix | implemented (see 0.7; this row postdates the 0.2 count) |
| Move checking | implemented |
| Shared-XOR-exclusive aliasing | implemented |
| Retain / release insertion for `arc` | partially implemented, C backend only: all four R11 retain sites, the `shared`-parameter non-retain, a retain for every returned `arc` place except a PARAMETER returned directly (a match-arm binding returned from a block arm body is retained, and spelling that exception as "not droppable" instead of "not a parameter" reopened a use-after-free once), and a retain for an `arc` place flowing out of an `if` branch, a `match` arm, or a block's trailing expression; release is the drop pass, function-scoped. **Six** leaks remain, and `docs/OWNERSHIP.md` R11 tables them with a `leaks` measurement each: an `arc` parameter is never released by a Cell body, a struct with an `arc` field is never dropped, an unbound `arc` temporary unboxed for a `shared` parameter drops its handle, a block-scoped `arc` local is never released (unbounded in a `while` body), reassigning an `arc` `var` leaks the previous box, and an `owned` place bound as `arc` is not boxed because R10's move-into-`arc` is unimplemented. SEVEN use-after-frees were found under earlier "leaks, never dangling" claims and are fixed with tests: a returned `arc` FIELD handed out unretained, a SHADOWED `arc` local released twice because drops are spelled by name, an `arc` place flowing out of an `if` branch, one flowing out of a `match` arm in return position, an `arc` place passed to an `owned` parameter, an `arc` match-arm binding returned from a BLOCK arm body (which the round that removed `Local.is_param` had derived to be unreachable), and `let owned ys: [Int] = xs`, a double free of the buffer that the parameter-position guard did not reach. The last two are refused by R10 rather than retained, since no retain can fix a double free of the buffer. Do not restate the categorical, and note that each of the three rounds was falsified by a FORM of a construct the previous round had not written out |
| Atomic refcounts in the runtime | implemented |
| Drop insertion for `owned` | partially implemented: unmoved `owned`/`arc` `let`/`var` locals only, function-scoped, conservative on moves; not structs, not parameters, not a value revived after a move (see `docs/OWNERSHIP.md` R16) |
| Copyability derivation | designed, not implemented |

### Expressions

| Construct | Status |
|---|---|
| Literal expressions | implemented |
| Identifier expressions | implemented |
| Name resolution | implemented |
| Field access `a.b` | implemented |
| Field existence and type resolution | implemented |
| Direct call `f(x)` | implemented |
| Postfix chaining `a.b(c).d` | implemented |
| Method dispatch and `impl` blocks | designed, not implemented |
| Binary operators (12) | implemented |
| Precedence and left associativity | implemented |
| Unary `-` and `!` | implemented |
| `&x` shared borrow | implemented |
| `&mut x` / `&exclusive x` | implemented |
| Parenthesized grouping | implemented |
| Tuples | designed, not implemented |
| Struct literal parsing, with field shorthand | implemented |
| Struct literal excluded from condition position | implemented |
| Struct literal lowering | implemented |
| List literal parsing | implemented |
| List literal lowering | implemented |
| `if` / `else` / `else if` parsing | implemented |
| `if` lowering to C control flow | implemented |
| `if` as a value-producing expression | implemented |
| Block expression parsing | implemented |
| Block expression lowering | implemented |
| Indexing `a[i]` | designed, not implemented |

### Statements

| Construct | Status |
|---|---|
| Optional semicolons | implemented |
| `let` binding | implemented |
| `var` binding | implemented |
| `let mut` | implemented |
| `var mut` accepted as redundant | designed, not implemented |
| Type annotation on a binding | implemented |
| Type inference | designed, not implemented |
| Definite assignment | designed, not implemented |
| Assignment statement with an expression target | implemented |
| Immutable-assignment check on the root binding | implemented |
| Parameter mutability derived from the ownership mode | implemented |
| Assignability check on the target | designed, not implemented |
| Block-scoped symbol table | implemented |
| Compound / indexed assignment | designed, not implemented |
| `return` | implemented |
| Return-type checking | implemented |
| Expression statement | implemented |
| Unused-result diagnostic | designed, not implemented |
| Loops and `break` / `continue` | designed, not implemented |

### Items

| Construct | Status |
|---|---|
| `fn` with a body | implemented |
| `fn` declaration without a body | implemented |
| Default parameters, variadics, generics on `fn` | designed, not implemented |
| Nested functions and closures | designed, not implemented |
| `struct` declaration and emission | implemented |
| Struct field separator standardization | designed, not implemented |
| `enum` declaration and emission | implemented |
| Enum variant payloads | designed, not implemented |
| Explicit enum discriminants | designed, not implemented |
| `use` declaration syntax | parsed, not enforced |
| Module resolution | designed, not implemented |
| `pub` recorded and marked in output | implemented |
| Visibility enforcement and `static` linkage | designed, not implemented |
| Item spans, printed by `cell dump` | implemented |

### Patterns

| Construct | Status |
|---|---|
| `match` expression parsing | implemented |
| Wildcard pattern `_` | implemented |
| Binding pattern | implemented |
| Enum variant pattern, bare and qualified | implemented |
| Literal patterns, including negative numbers | implemented |
| Uppercase-first variant heuristic replaced by resolution | designed, not implemented |
| Payload, struct, tuple and slice patterns | designed, not implemented |
| Or-patterns and guards | designed, not implemented |
| Range patterns | designed, not implemented |
| Exhaustiveness and unreachable-arm checking | designed, not implemented |
| Pattern binding ownership | designed, not implemented |
| `match` lowering to C | implemented |

### C ABI

| Construct | Status |
|---|---|
| Single-translation-unit emission | implemented |
| Header emission and `extern "C"` | designed, not implemented |
| `cell_<name>` mangling on definitions | implemented |
| Mangling on call sites | implemented |
| Primitive parameter mapping | implemented |
| `String` as a length-prefixed slice | implemented |
| Ownership lowering at the boundary | implemented for all five modes in the C backend (see 10.4) |
| `const` for `shared` aggregates | implemented |
| `arc` as `cell_arc_t` | implemented in the C backend, in every position including an un-annotated `let` |
| `cell_result_t` emission | designed, not implemented |
| Return-value mapping | implemented |
| Emitted C compiles for declaration-only files | implemented |
| Emitted C compiles for hello / control_flow / ownership | implemented |
| Runtime host intrinsics exist | implemented |
| Generated code can call the host intrinsics | implemented |
| Panic lowering | implemented |

### Files and diagnostics

| Construct | Status |
|---|---|
| Single-file compilation | implemented |
| `.cell` / `.cel` module files | implemented |
| `.body` / `.bod` body files | implemented |
| Stem-based module/body pairing | implemented |
| Diagnostic record, bag, levels and spans | implemented |
| Caret rendering with the source line | implemented |
| Parser records a span and a message on failure | implemented |
| CLI surfaces parser diagnostics | designed, not implemented |
| Check diagnostics rendered through `Bag.render` | implemented |
| Error recovery past the first failure | designed, not implemented |

---

## 13. Grammar summary

The grammar the parser accepts at `9fb12af`, in EBNF. Constructs marked
**designed, not implemented** above are absent on purpose: this is the
implemented grammar, not the specified one.

```ebnf
module     = item* EOF ;

item       = [ "pub" ] ( fn_item | struct_item | enum_item | use_item ) ;

fn_item    = "fn" ident "(" [ param { "," param } ] ")" [ "->" type ]
             ( "{" stmt* "}" | [ ";" ] ) ;
param      = [ ownership ] ident ":" type ;

struct_item = "struct" ident "{" { field } "}" ;
field       = [ ownership ] ident ":" type [ "," ] [ ";" ] ;

enum_item   = "enum" ident "{" { ident [ "," ] } "}" ;

use_item    = "use" path [ ";" ] ;
path        = ident { "." ident } ;

ownership  = "owned" | "shared" | "exclusive" | "arc" | "copy" ;

type       = "[" type "]"
           | ownership type
           | ident [ "?" ] ;

stmt       = let_stmt | return_stmt | assign_or_expr_stmt ;
let_stmt   = ( "let" | "var" ) [ "mut" ] [ ownership ] ident
             [ ":" type ] [ "=" expr ] [ ";" ] ;
return_stmt = "return" [ expr ] [ ";" ] ;
assign_or_expr_stmt = expr [ "=" expr ] [ ";" ] ;

expr       = or_expr ;
or_expr    = and_expr   { "||" and_expr } ;
and_expr   = eq_expr    { "&&" eq_expr } ;
eq_expr    = cmp_expr   { ( "==" | "!=" ) cmp_expr } ;
cmp_expr   = add_expr   { ( "<" | "<=" | ">" | ">=" ) add_expr } ;
add_expr   = mul_expr   { ( "+" | "-" ) mul_expr } ;
mul_expr   = unary      { ( "*" | "/" ) unary } ;

unary      = "-" unary
           | "!" unary
           | "&" [ "mut" | "exclusive" ] unary
           | postfix ;

postfix    = primary { "." ident | "(" [ expr { "," expr } ] ")" } ;

primary    = [ ownership ] unary            (* the ownership is discarded *)
           | int | float | string | "true" | "false"
           | ident [ struct_lit ]           (* struct_lit only when allowed *)
           | "(" expr ")"
           | "[" [ expr { "," expr } ] "]"
           | "{" stmt* "}"
           | if_expr
           | match_expr ;

struct_lit = "{" { ident [ ":" expr ] [ "," ] } "}" ;

if_expr    = "if" expr_no_struct_lit "{" stmt* "}"
             [ "else" ( if_expr | "{" stmt* "}" ) ] ;

match_expr = "match" expr_no_struct_lit "{" { arm [ "," ] } "}" ;
arm        = pattern "=>" expr ;
pattern    = "_" | ident [ "." ident ]
           | [ "-" ] int | [ "-" ] float | string | "true" | "false" ;
```

`expr_no_struct_lit` is an ordinary `expr` parsed with the struct-literal
restriction of section 6.7 in force. The restriction is lifted inside
parentheses, brackets, and call arguments.

---

## 14. Related documents

- `docs/OWNERSHIP.md`: the numbered, enforceable rules for the borrow checker.
- `examples/README.md`: the pass/fail contract every example must satisfy.
- `runtime/cell_rt.h`: the authoritative C ABI value model (section 10.3).
- `README.md`: build and run instructions.
