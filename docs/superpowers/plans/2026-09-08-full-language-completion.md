# Cell full-language completion program

Approved by Donald on 2026-09-08. Baseline: `584162a` on canonical `main`.

## Binding decisions

Complete the described language and reserved systems with C, LLVM and MLIR
parity, qualified on macOS ARM64, Linux x86-64 and Windows x86-64. Migrate
incrementally to shared typed IR and explicit ownership/cleanup operations.
Preserve a working compiler throughout. Use monomorphized generics, coherent
traits with explicit trait objects, inferred local lifetimes and explicit
escaping-reference contracts. Borrow assignment remains write-through;
borrow-valued retargeting remains invalid.

ABI version 2 carries typed generic payloads with explicit legacy error-code
adapters. Closures infer captures; async and generators use owned state
machines and cancellation cleanup. Execution is opt-in through a cooperative
executor or host interface. Unsafe permits raw pointers and foreign operations,
not disabling ordinary ownership checks. Panics abort across host boundaries.

The release includes the declared prelude, core collections, iteration,
allocation, errors, FFI, weak ARC, futures, compiler build/run/test commands,
generated headers and an installable SDK. Package publishing, networking,
formatter and language server are excluded.

## Ordered milestones and acceptance

1. **Contract and gate:** one evidence-backed feature matrix; strict validation
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
8. **Closures/async/unsafe:** capture and suspension analysis, owned frames,
   cancellation, generators, executor primitives and checked foreign boundaries.
9. **Core library/CLI:** implement retained prelude declarations, build/run/test,
   target/module roots, headers, structured diagnostics and extracted-SDK usage.
10. **Qualification/release:** pinned toolchains, hosted three-platform matrix,
    portable optional Swift integration, complete archives, independent review,
    published versioned artifacts tied to the final qualified SHA.

Each milestone needs all three backend implementations to be complete. A
temporary refusal is a development boundary, not completed parity.

## Execution contract

Use fresh task implementers with independent spec/quality review and a broad
final review. Serialize writers sharing compiler interfaces. Parallel read-only
investigation is allowed. Work on canonical main, preserve concurrent work,
record explicit BASE..HEAD review ranges and use conventional scoped commits.
Use Zig master and -Dswift=false for ordinary validation. All frontend/lowering
changes require tools/check.sh and meaningful named regression evidence.

Reports distinguish source inspection, local tests, pushes, hosted qualification
and release acceptance. No milestone is complete solely because it parses,
builds, or passes a subset of checks.

## Verification obligations

Test malformed input and recovery; resolution and typing; borrow/move/drop
paths including cancellation; runtime answers and independent expected exit
statuses; IR validation and backend parity; bidirectional real C ABI calls;
fault-injected gate failures; Debug/ReleaseSafe and optimized regressions;
C++ enabled/disabled and deliberate Swift integration; extracted packages.

Generated differential sweeps retain failing reproductions and promote defects
to deterministic fixtures. A clean sweep is never an exhaustive safety proof.
