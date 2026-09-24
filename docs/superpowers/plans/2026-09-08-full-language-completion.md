# Cell full-language completion program

Approved by Donald on 2026-09-08. Baseline: `584162a` on canonical `main`.
Systems-capability scope amended 2026-09-24; current evidence lives in
[FEATURES.md](../../FEATURES.md), not in that historical baseline.

## Binding decisions

Complete the core systems language with C, LLVM and MLIR parity, qualified on
macOS ARM64, Linux x86-64 and Windows x86-64. Parity means Cell can perform
the practical systems roles of C, C++, Rust, Swift and Zig; it does not mean
copying the union of their syntax or every feature. Migrate incrementally to
shared typed IR and explicit ownership/cleanup operations.
Preserve a working compiler throughout. Use monomorphized generics, coherent
traits with explicit trait objects, inferred local lifetimes and explicit
escaping-reference contracts. Borrow assignment remains write-through;
borrow-valued retargeting remains invalid.

ABI version 2 carries typed generic payloads with explicit legacy error-code
adapters. Closures infer captures. Unsafe permits raw pointers and foreign
operations, not disabling ordinary ownership checks. No exception, panic or
unwind silently crosses a Cell boundary. The stable C ABI is the documented
distribution contract. Direct native C++, Swift, Rust and Zig integration is
best effort for explicitly tested compiler and platform combinations; an
unsupported combination must be refused or directed to the C ABI adapter.

The release includes the declared prelude, core collections, iteration,
allocation, errors, FFI, weak ARC, compiler build/run/test commands, generated
headers and an installable SDK. SIMD, general threading and atomics,
compile-time metaprogramming beyond deterministic constants, generators,
futures and async runtimes are separate future programs. Package publishing,
networking, formatter and language server are excluded.

## Ordered milestones and acceptance

1. **Contract and gate:** split broad matrix rows into testable capabilities.
   Each contract records accepted and rejected Cell programs, runtime answers,
   ownership/failure behavior and C/LLVM/MLIR support. Pin strict validation
   and structured reports; crashes, count failures and invalid signature-only
   MLIR fail. Historical prose is not current qualification evidence.
2. **Existing defects:** reproduce and fix unsafe accepted programs with
   minimized tests; reject unsupported dangerous conversions in the frontend.
   Never loosen disclosed baselines to hide a regression.
3. **Shared semantics:** stable symbols/types/bindings/places, explicit effects
   and CFG ownership operations. Move C behind the shared pipeline only after
   differential execution proves each migrated construct.
4. **Ownership:** path-sensitive moves, partial initialization, escaping loans,
   aggregate/parameter cleanup, ARC transfer/reassignment, copyability, defer.
   All promised cleanup reaches zero outstanding allocations; cycles require
   weak references rather than an implied collector.
5. **Lexical/scalar/control flow:** complete literals, strings, Unicode names,
   widths, casts/operators, tuple/unit, indexing, initialization, for/loop,
   labeled exits, aliases/constants/statics and deterministic constant evaluation.
6. **Generics/traits/patterns:** constraints, associated types/methods, coherent
   implementations, payload enums, optionals/Result, exhaustive destructuring.
   Reject overlap, ambiguous resolution and runaway instantiation.
7. **Modules/ABI v2:** deterministic module roots, visibility/reexports, pairing,
   qualified symbols, generated headers, callable runtime constructors and
   AAPCS64/System V AMD64/Windows x64 ABI classification.
8. **Closures/unsafe/interop:** capture analysis, checked foreign boundaries,
   ownership-aware bidirectional C, C++, Swift, Rust and Zig profiles, and
   generated adapters. Each native profile names its tested compiler versions,
   target platform, supported type and call subset, and C ABI fallback.
9. **Core library/CLI:** implement retained prelude declarations, build/run/test,
   target/module roots, headers, structured diagnostics and extracted-SDK usage.
10. **Qualification/release:** pinned toolchains, hosted three-platform matrix,
    extracted-SDK consumers and bidirectional interop examples, complete
    archives, independent review, and versioned artifacts tied to the same
    qualified SHA on every target platform.

Each completed capability needs named compiler tests, positive and negative
Cell fixtures, matching C/LLVM/MLIR execution results, and ownership or
failure-path tests where relevant. Each milestone needs all three backend
implementations to be complete. A temporary refusal is a development
boundary, not completed parity. Disclosed leak pins must reach their stated
zero target before the default backend changes.

## Execution contract

Use fresh task implementers with independent spec/quality review and a broad
final review. Serialize writers sharing compiler interfaces. Parallel read-only
investigation is allowed. Work on canonical main, preserve concurrent work,
record explicit BASE..HEAD review ranges and use conventional scoped commits.
Use Zig master and -Dswift=false for ordinary validation. Capture the actual
exit code and verdict of tools/check.sh. All frontend/lowering changes require
that gate and meaningful named regression evidence. Do not push without a
separate request.

Reports distinguish source inspection, local tests, pushes, hosted qualification
and release acceptance. No milestone is complete solely because it parses,
builds, or passes a subset of checks.

## Verification obligations

Test malformed input and recovery; resolution and typing; borrow/move/drop
paths; runtime answers and independent expected exit
statuses; IR validation and backend parity; bidirectional real C ABI calls;
fault-injected gate failures; Debug/ReleaseSafe and optimized regressions;
C++ enabled/disabled and deliberate Swift/Rust/Zig integration; extracted
packages. Release claims require results from the same source revision on
macOS ARM64, Linux x86-64 and Windows x86-64, not a green local gate alone.

Generated differential sweeps retain failing reproductions and promote defects
to deterministic fixtures. A clean sweep is never an exhaustive safety proof.
