# Remaining milestone 1 acceptance contracts

Independent contract audit after the initial capability matrix. The matrix is
an accurate static status entry point for its reviewed rows, but is not yet a
complete set of independently executable acceptance contracts. Milestone 1
remains incomplete.

## Matrix expansion task

Keep one authoritative matrix in `docs/FEATURES.md`. Split broad summary rows
and attach explicit acceptance tests for the following required systems:

| System | Acceptance obligation |
| --- | --- |
| Integer widths, radix and separators | Every width boundary and adjacent invalid value; equivalent radix values; precise malformed-literal diagnostics |
| Floating literals and exponents | Boundary, exponent, overflow/underflow and invalid-token contracts |
| Arithmetic, casts and operators | Explicit overflow, division, remainder, shift and narrowing policy; Debug and optimized agreement |
| Strings and Unicode | Byte-exact decoded escapes; invalid scalar/encoding rejection; identifier validation |
| Tuples and unit | Grammar, nested layout, destructuring, owning payload cleanup and independent host round trips |
| User type aliases | Distinguish aliases from existing primitive spelling synonyms; chains, cycles and visibility |
| Constants and deterministic evaluation | Dependency order, cycles, forbidden runtime operations and bounded evaluation |
| Static storage | Initialization, linkage, mutability, concurrency and destruction policy |
| Indexing and compound assignment | First/last/empty/out-of-bounds; exclusive writes; shared write refusal; element ownership |
| for/in, loop and labeled exits | Iterator ownership, backedges, nested exits, break values and cleanup |
| defer | LIFO cleanup on normal exits; explicit abort behavior |
| Traits, impl, where, self/Self and associated types | Coherence, constraints, receiver modes, static dispatch and bounded resolution |
| Explicit trait objects | Construction, object-safe methods, dynamic dispatch, layout and destruction |
| Async/await and generators/yield | Suspension, completion, cancellation, early drop and stable-storage proofs |
| Unsafe/raw pointers/foreign operations | Explicit boundary while ordinary ownership checks remain active |
| Panic abort | Deterministic diagnostics, nonzero termination and no unwinding across host frames |
| Imports/reexports and foreign exports | Deterministic module roots, visibility, collision-free symbols and generated headers |
| Core allocation/collections/errors/weak ARC/executor | Every retained declaration links; failure injection; typed payload cleanup and lifecycle tests |
| Extracted SDK | Consumer works without repository paths; headers compile as C and C++ |
| Diagnostic recovery and JSON | Stable identifiers, primary/related spans, ordered independent errors; no lowering after checking failure |

Every reserved keyword must map to a named row. Distinguish a chosen language
contract from an open policy decision. Arithmetic failure policy, string
indexing units, loop break values and static destruction require reviewed
milestone designs before implementation; do not silently inherit host behavior.

## Local qualification is not language-release completion

The current report wrapper samples one host and the current corpus. Its
`release_ready` field must not become true merely because this subset has no
skips, disclosures or dirty files. A follow-up should expose local gate
qualification explicitly and keep global release readiness false until a
separate release evaluator checks all required feature rows and same-SHA
macOS ARM64, Linux x86-64 and Windows x86-64 reports, including SDK and ABI
obligations. Current real reports already say false because disclosures remain.

Required fault injection: a clean synthetic local report with any unqualified
feature or missing platform must not claim global release readiness. Preserve
strict mode as a local missing-stage/tool refusal; it cannot stand in for the
full language/platform acceptance matrix.
