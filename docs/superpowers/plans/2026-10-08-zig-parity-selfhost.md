# Zig master parity and Cell self-hosting execution ledger

Status: Partial. This records the currently authorized scope and verified work;
it does not certify parity, self-hosting, or release qualification.

## Current scope

Use the installed Zig master baseline, preserving Cell syntax and ownership.
Complete language capabilities first, then implement the compiler, analysis,
libraries, language server, syntax/semantic highlighting, and terminal editor
in Cell. Retain only unavoidable OS/backend primitives outside Cell. Qualify
on native macOS, Linux, and Windows. This scope supersedes the exclusions of
metaprogramming, threading/atomics, networking, formatter, and language server
in the earlier full-language completion program.

## Implemented slices

- Toolchain baseline: `0.18.0-dev.120+9fe22a29b`; existing manifest pin agrees.
- Reproducible installed language-reference, command, target, and std source
  inventory. Extraction tooling is Zig/Python bootstrap tooling, not self-hosted.
  See `docs/ZIG-PARITY.md` for its semantic completeness boundaries.
- Byte and Unicode scalar string escapes with malformed-scalar rejection.
- Dependency-ordered module graphs, deterministic roots, cycle/ambiguity
  rejection, paired interface/body files, embedded `std.prelude`, qualified
  public functions/structs/enums, nominal identity, and private native linkage.
- Graph-aware ownership signature resolution, borrowed-result consumption
  rejection, source provenance, hygienic whole-program composition, and
  unused imported external declaration pruning.
- Runtime symbol/prototype validation from preprocessed runtime declarations.
- LLVM entry wrapper respects return ABI and forwards integer exit status.
- Fixed-width integer `&`, `|`, `^`, `~`, `<<`, and `>>` on C/LLVM/MLIR,
  preserving width and single source-order evaluation. Signed right shifts
  are arithmetic; dynamic invalid counts panic before shifting. Literal peer
  typing checks range, nested `Result` closing tokens remain valid, and
  newline-leading borrow statements retain their boundary semantics.
- Explicit newline-escaped corpus expectations, with exact output comparisons
  and malformed/conflicting marker rejection.
- Curated installed-capability coverage and qualification contracts, covering
  every extracted language heading/builtin, std root export, compiler command
  and source-directory family. This is discovery accounting, not semantic API
  reachability or implemented parity; see
  [capability contracts](../../ZIG-CAPABILITY-CONTRACTS.md).

## Qualification receipts

On 2026-10-08, the final stable `tools/check.sh` run exited 0 with a
`clean` verdict. It reported 865 library tests, checked the CLI/runtime test
suite, compared 39 backend-answer programs, and ran 69 programs under
AddressSanitizer. All disclosed leak baselines matched, 44 prelude prototypes
matched the runtime header, and public/private linkage controls passed across
C/LLVM/MLIR. The module fixture prints 43 and the nominal enum pattern fixture
prints 11 on all three backends. The independent gate-integrity helpers passed.

Receipts: `/private/tmp/cell-stable-gate.log` and
`/private/tmp/cell-stable-gate.exit`; focused results include runtime reservation
3/3, provenance diagnostics 9/9, and 11 compiled/runtime entry-wrapper cases.
Inventory helper tests passed 3/3 and Python inventory tests passed 5/5.
No Linux/Windows native execution, full Zig parity, or self-hosting is implied.

The subsequent integer-operator gate on 2026-10-08 exited 0 with a `clean`
verdict: 882 library tests, 40 backend-answer programs (38 output pins),
70 AddressSanitizer programs, and 608 compared function signatures across
54 examples with zero disagreements. Disclosed leak baselines still match.
The integer fixture produces identical exact 21-line output on C/LLVM/MLIR.
The runtime shift harness passed 415 checks, including a separate UBSan run.
Spec compliance and code quality reviews passed after parser and expectation
integrity fixes. Receipt: `/private/tmp/cell-bits-release-gate.log` and
`/private/tmp/cell-bits-release-gate.exit`. Interrupted and failed earlier
runs are not acceptance receipts. The compiler remains Zig and runtime C.

The subsequent read-only contract audit refreshed the installed inventory
byte-for-byte against the prior snapshot and mechanically checked partitions
for 355 headings, 124 builtins, 92 public std root declarations, 30 commands
and all 31 directory families/564 source files: zero omissions, extras or
duplicates. Independent documentation/data review passed. A focused existing
primitive-parameter probe checked and ran on C/LLVM/MLIR, confirming that
`exclusive Int` mutation does not write through to the caller under today's
explicit by-value contract. Receipts:
`/private/tmp/cell-parity-contract-validation.log` and `.exit`,
`/private/tmp/cell-scalar-exclusive-contract.log` and `.exit`.
No product code changed or full code gate was rerun for this documentation work.

## Remaining ordered work

1. Retain every disclosed leak pin and unsupported IR boundary until actually
   implemented; this module slice passed the native macOS gate and review.
2. Resolve semantic reachable APIs and complete operation-level capability
   records from the installed-family map, with accepted/refused fixtures,
   runtime answers, failure paths, implementation-language and platform evidence.
3. Complete the language/type/ownership/IR surface: generics, payload enums,
   compile-time execution/reflection, pointers/layout/ABI, iteration and remaining
   scalar/control-flow features, SIMD, atomics/threading, and cleanup parity.
   Donald selected full `comptime` interpreter design before a scalar-only
   constant implementation on 2026-10-08. The Proposed design is
   [full comptime interpreter](../specs/2026-10-08-full-comptime-interpreter-design.md);
   written design review precedes its detailed implementation plan.
4. Provide installed-stdlib-equivalent capabilities and build/target/package
   tooling, with bounded resource behavior and explicit unsupported cases.
5. Bootstrap and compare a Cell-written compiler/analysis/library implementation;
   demonstrate reproducible successive self-hosted generations.
6. Build the Cell-written LSP, syntax/semantic highlighting, and terminal editor
   on the verified analysis and runtime interfaces; qualify protocol/editor behavior.
7. Run native macOS/Linux/Windows qualification against identical source and
   toolchain manifests. Only then report complete parity and self-hosting.

No commits, pushes, release publication, or deployment have been authorized.
