# Installed Zig capability qualification contracts

Status: Partial. This is an acceptance map, not an implementation plan or a
claim of feature parity. It preserves the full language, library, toolchain,
self-hosting, LSP, highlighting, editor and native-platform objective.
The full `comptime` design awaits written-spec approval independently.

The 2026-10-08 baseline is installed Zig `0.18.0-dev.120+9fe22a29b`.
Refreshing `tools/zig-parity.py` produced the same 6,266,467-byte inventory as
the prior snapshot, SHA-256
`1a1d06c4986f94be3ac633642df2f1c2de5a64aa9f6b86dbcb418030a929a9ef`.
The curated [coverage map](zig-parity-contracts.json) binds its partitions to
that inventory, language reference, stdlib manifest and target manifest.

The partitions account for all 355 extracted reference headings, 124 builtin
headings, 92 public root declarations in `std.zig`, 30 compiler commands and
31 stdlib directory families containing 564 files. Mechanical comparison
found no missing, extra or duplicated entries in these partitions. This proves
discovery coverage only: aliases, type-generated APIs, constraints, target
conditions and semantic reachability remain to be resolved. The 28,243 public
source declarations include nested/test-local declarations; they are not a
count of reachable user APIs. See [inventory limitations](ZIG-PARITY.md).

## Evidence rules

`Partial` means a related frontend/backend/runtime facility exists with
explicit restrictions. `Absent` means no public corresponding capability was
found in the inspected AST/types/registered library surface. Neither means
equivalent behavior has been established. Proposed designs remain Proposed.
Current case receipts apply to those cases, not an entire family.

Each operation-level record must identify its pinned Zig declaration/anchor
and constraints, Cell spelling/type/ownership contract, implementation files
and language, supported target conditions, accepted and refused fixtures,
independent expected answers, cleanup/failure witnesses and native receipts.
Separate frontend, C, LLVM, MLIR, runtime, target and self-hosting evidence.
A Cell refusal proves a safe boundary; it does not satisfy positive parity.
Cell syntax and ownership may differ, but every claimed equivalent capability
needs an executable mapping rather than a similarly named declaration.

The latest code receipt is `/private/tmp/cell-bits-release-gate.log` and `.exit`:
exit 0, 882 library tests, 40 backend-answer programs, 70 AddressSanitizer
programs and 608 signatures across 54 examples. Disclosed nonzero leak pins
remain incompleteness evidence. This receipt qualifies native macOS cases,
not Linux/Windows, arbitrary target ABIs, full language/library parity or
strict self-hosting. Source inspection in this map did not rerun those cases.

## Language families

Exact heading index ranges are in `heading_groups` in the coverage map;
indices refer to the bound inventory. Root names and HTML anchors refer to
the installed `doc/langref.html`, not remembered documentation from another
Zig version. [FEATURES.md](FEATURES.md) is the current Cell status entry point;
historical SPEC/AGENTS snapshots do not override live source and newer receipts.

| Family | Current Cell subset and evidence | Qualification needed for the complete family |
| --- | --- | --- |
| Reference metadata | Introduction/documentation/navigation headings are discovery metadata; the embedded prelude is a Partial stdlib entry point ([prelude](../stdlib/prelude.cell)). | Introductory equivalent programs and API-level contracts. Do not turn table-of-contents or style headings into invented runtime features. |
| Lexing/grammar | Partial ASCII identifiers, numeric literals, comments, decoded byte/Unicode scalar string escapes ([lexer](../src/cell/lexer.zig), [parser](../src/cell/parser.zig), [escapes](../examples/string_unicode.cell)). | Source encodings, malformed input/spans, quoted and Unicode identifiers, multiline/advanced strings, hexadecimal floats, every precedence and ambiguity rule. Reserved words alone are not grammar support. |
| Names/bindings | Partial local let/var, assignments, modules and qualified exports. No global variable/TLS/general destructuring item ([AST](../src/cell/ast.zig), [modules](../examples/modules/main.cell)). | Globals/initialization, TLS isolation, destructuring evaluation/ownership, scopes/shadowing, mutation and definite initialization. |
| Numbers/operators | Partial fixed 8/16/32/64-bit integers/Byte and f32/f64; checked width-preserving bit operations ([types](../src/cell/types.zig), [integer fixture](../examples/integer_bits.cell)). | Arbitrary/zero widths, large literals, casts/peer resolution, overflow modes, exact/saturating/wrapping operations, compound assignment, division/rounding rules, NaN/infinity/signed zero and source-order effects in both phases. |
| Arrays/vectors/pointers/slices | Partial lists/ownership borrows; general fixed arrays, raw pointers, vector and sentinel/address-space types absent ([type AST](../src/cell/ast.zig)). `[T]` is a Cell list, not Zig's `[N]T`. | Fixed/multidimensional/zero-length arrays, sentinels, slices, pointer qualifiers/arithmetic/alignment/null/volatile access, alias rules, vector masks/shuffles/reductions and target lowering. |
| Aggregates/layout | Partial named structs, payload-free enums and return-only unit ([AST](../src/cell/ast.zig), [struct fixture](../examples/structs_enums.cell)). | Payload/nonexhaustive enums/discriminants, tuples/unions/opaque types, default/extern/packed layout, zero-bit types, offsets/alignment, active-union safety and destination-driven initialization at every expression shape. |
| Control flow | Partial if/block/match, while/loop, labelled jumps ([labels](../examples/labels.cell), [checker](../src/cell/typecheck.zig)). | Iteration, value-bearing jumps, exhaustive matches/guards, captures, inline control flow, defer/error cleanup and all exits/divergence/unreachable behavior. |
| Functions | Partial named typed functions/calls. Function values, calling-convention controls, inferred/generic parameters, closures and inline controls incomplete or absent ([function AST](../src/cell/ast.zig)). | Recursive/indirect/inline calls, inference, erased compile-time arguments, reflection, call modifiers and ABI/exact evaluation order. |
| Errors/optionals | Partial scalar Optional/Result across backends; owning String wrappers C-only ([optional fixture](../examples/optionals.cell), [Result fixture](../examples/results_string.cell)). No Zig error-set/try/catch/errdefer/tracing model. | Error-set inference/merging/casts, propagation/catches/traces, error-only cleanup, nested/resource wrappers, invalid unwraps, optional-pointer representation and exactly-once destruction. Result is not proof of error-union parity. |
| Comptime/generics/reflection | Absent public evaluator, metatype and general specialization; host Zig comptime is not Cell support ([AST](../src/cell/ast.zig), [Proposed design](superpowers/specs/2026-10-08-full-comptime-interpreter-design.md)). | Complete admitted expression/type/control-flow evaluation; phase separation, dependent/generated types, identity/instantiation, quotas, effects, diagnostics, reflection and runtime materialization. |
| Assembly | Absent public assembly expression/item ([AST](../src/cell/ast.zig)). | Global/inline assembly, target constraints, clobbers, volatile effects, symbols and executable calling-convention checks. |
| Atomics/concurrency | General language atomics/TLS absent; atomic ARC refcounts are a narrow runtime substrate ([runtime](../runtime/cell_rt.c)). | Memory orders, compare-exchange success/failure, publication/contended tests, TLS and single-thread controls on each target. Historical Zig async syntax is not current-master functionality; inspect current `std.Io` concurrency instead. |
| Safety/memory | Partial borrow rules and cleanup with disclosed residuals ([OWNERSHIP.md](OWNERSHIP.md), [leak contracts](../examples/leaks/README.md)). Cell checked indexing returns Optional rather than Zig's bounds trap. | Every illegal-behavior/optimization-mode contract, allocation failure, recursion and lifetime exits. Record deliberate ownership/safety differences; matching nonzero leak pins does not prove cleanup completion. |
| Compilation/C/targets | Partial local graphs, privacy, pairing and embedded prelude; ABI source is AAPCS64 measured on Apple ARM64 ([loader](../src/cell/load.zig), [ABI](../src/cell/abi.zig)). | Compile variables, packages/aliases/reexports, separate compilation, C translation/varargs/exports, objects/libraries, ABI round trips and WASM/WASI/freestanding/native target contracts. |
| Language testing | Partial C-target directory-program driver; test declaration/doctest AST absent ([CLI](../src/main.zig), [test contracts](../tests/README.md)). | Discovery/filtering/skips/failures/doctests, test-build detection, logging/leaks, harness/test-object ABI and rejection of false coverage from empty selections. |

The installed reference's `Async-Functions` section explicitly records the
regression of that historical syntax since Zig 0.11.0. This does not remove
Cell's broader concurrency work or modern `Io` futures/cancellation from scope.

## Compiler builtin coverage

`builtin_groups` names every extracted builtin exactly once. Cell has no
general compiler-builtin namespace today; ordinary calls/fields/imports and
runtime helpers supply limited analogues. Every builtin needs its signature,
admissible types, phase requirements, legal/illegal input contracts, target
restrictions and executable answer/diagnostic witnesses.

| Group | Count | Additional proof boundary |
| --- | --- | --- |
| Numeric | 35 | Overflow/exactness/division, bit counting, byte order, transcendental/rounding accuracy and float mode. |
| Casts | 13 | Range, representation, error/enum identity and phase-dependent diagnostics. |
| Pointers/memory | 12 | Provenance, access/qualifier/alignment/address space, overlap and volatile semantics. |
| Layout | 7 | Target-dependent sizes, alignments, offsets, packed backing integers and zero-bit types. |
| Vectors | 5 | Lane type/count, masks, shuffle/select/reduction and target legality. |
| Errors | 2 | Error name identity and supported return-trace behavior. |
| Comptime/reflection/type construction | 25 | Includes installed `Int`, `Pointer`, `Fn`, `Struct`, `Union`, `Enum` constructors; do not use an older builtin list. |
| Functions/C ABI | 7 | Call modifiers, import/export identity and complete varargs ABI/lifetimes. |
| Atomics | 5 | Allowed orders and target atomic instructions/fallbacks. |
| Debug/safety/codegen | 7 | Safety toggles, traps/panic, frame/return address restrictions and branch hints. |
| Target-specific | 6 | WASM memory operations and SPIR-V types/workgroup/workitem queries. |

## Standard-library families

`stdlib_root_groups` covers all 92 public source-root declarations, including
aliases. `stdlib_file_groups` covers all 564 hashed source files through their
31 directory families. A file's disposition must eventually distinguish
reachable public APIs, aliases, generated types, target implementations,
private helpers and test support. Group coverage is not semantic reachability.

Only `std.prelude` is currently embedded ([registration](../src/main.zig));
its functions are bodyless declarations backed by C. No whole Zig stdlib
family qualifies as implemented in Cell under the strict self-hosting rule.

| Family / root group | Current subset | Required behavior/resource evidence |
| --- | --- | --- |
| Allocation/memory | Partial C-backed String/slice and host arena substrate; Cell allocator library absent. | Allocator identity/alignment, initialization, overflow, resize/remap, OOM, reset invalidation, free ownership and threading. |
| Lists | Partial Byte operations and five scalar construction/index paths. | Generic elements, capacity/growth failure atomicity, borrowed-pointer invalidation, moves/drop glue and exactly-once cleanup. |
| Hash tables/sets | Absent registered library. | Hash/equality consistency, key ownership, collisions, ordering/invalidation, compile-time construction and OOM. |
| Other containers | Absent registered library. | Intrusive lifetimes, comparator/order rules, bit/enum indexing, bounds/empty states, invariant and cleanup checks. |
| Text | Partial String and formatting primitives; Unicode/ASCII library absent. | Bytes versus scalars, malformed UTF, numeric parse/format round trips, locale and allocation/output limits. |
| Encodings/structured formats | Base64/LEB/JSON/ZON/URI/SemVer absent. | Streaming/truncation, duplicates/unknown fields, owned/borrowed parse trees, canonicalization and depth/size limits. |
| Math/vectors | Partial conversions/min/max/abs/remainder; SIMD absent. | Overflow, NaN/infinity/signed zero, rounding/transcendental accuracy, lanes and fallback equivalence. |
| Hash/sort/random | Absent registered library. | Algorithm/seed vectors, endian independence, ordering/stability, comparator constraints, seeded determinism versus secure entropy. |
| I/O/paths | Partial stdout/stderr only. | Readers/writers, partial operations/EOF, cancellation/timeouts, buffering/flush, handle close, native errors, path encodings/permissions/races. |
| Process/loading | Absent application library; host CLI execution is not that library. | Arguments/environment, pipes, spawn failures, wait/reap, exit/signal forwarding, cancellation and symbol/unload lifetime. |
| Concurrency | Partial atomic ARC substrate only. | Join/detach, mutex/condition, alignment/order, races/publication, cancellation and ownership across threads. |
| Clock/calendar | Absent registered library. | Monotonic/wall clocks, units/overflow/jumps, timezone version/DST ambiguity and injectable deterministic clocks. |
| HTTP | Absent registered library. | Client/server framing, body limits, redirects, connection reuse/ownership, TLS verification, timeouts and partial streaming. |
| Cryptography | Absent registered library. | Exact algorithm vectors/rejection, constant-time requirements, key/secret ownership and clearing, entropy failure, nonce rules and certificate validation. |
| Compression/archives | Absent registered library. | Installed codecs' actual encode/decode operations, streaming/truncation/checksums/dictionaries, limits and extraction path/symlink/metadata safety. |
| Diagnostics | Partial assertions/panic/output. | Structured logs/scopes/levels, progress, stack/symbol handling, reliable stderr and concurrency/terminal behavior. |
| Testing/instrumentation | Partial assertions/host program-test command. | Error assertions, temporary resources, leak/OOM injection, deterministic seeds and instrumentation availability. |
| Build/target | Partial host CLI/ABI substrate; Cell build graph/target library absent. | Dependency/cache identities, declared tool inputs, reproducible outputs, CPU/target features and separate cross/native proof. |
| Platform/C | Partial C ABI substrate; Cell OS binding modules absent. | Every target's layout/calling conventions, errno/error mapping, handle ownership, native operations and availability checks. |
| Object/debug/GPU formats | Absent application library; emitting IR is not a format API. | Formats/versions, byte order/bounds, relocations/debug traversal, malformed data and shader execution/address spaces. |
| Compiler/language | Cell reflection/AST/analysis libraries absent; bootstrap compiler is Zig. | Type construction/introspection, syntax/semantics, diagnostics/source ownership and stable identities. `builtin` aliases `lang`; count it as an alias, not a second implementation. |
| Startup/configuration | Equivalent Cell surface absent. | Entry ABI, initialization/relocation, compile-time options, panic/log/I/O overrides and disabled features. |

Source-grounded contracts that change the work:

- Modern installed `Io` includes readers/writers, files/directories,
  networking, futures, cancellation, synchronization, time and entropy.
  A map based only on historical `std.fs`/`std.net` names misses capabilities.
- OS paths require an encoding contract separate from Unicode text: arbitrary
  POSIX bytes, Windows WTF-16/WTF-8 and WASI constraints are different.
- Current allocation primitives have different failure behavior: String
  construction returns a zero value, reserve returns false and typed pushes
  panic. Equivalent libraries need explicit recoverable/fatal contracts and
  injected-failure witnesses, not just an allocator-shaped interface.
- Current `cell_print` adds a newline and `cell_println` delegates to it;
  prelude descriptions alone cannot prove different output behavior.
  Float formatting through host `snprintf` does not establish locale/target
  independent answers.

OS/backend primitives may expose raw virtual memory, handles, clocks, entropy,
thread/futex operations, atomic instruction lowering and native calling/startup
interfaces. Allocator/container algorithms, Unicode, formatting/parsing,
hashes/sort, codecs/archive traversal, HTTP/TLS logic, target/build processing,
testing and compiler analysis must reside in Cell. Wrapping whole C/Zig
libraries does not meet this requirement. Any acceleration primitive needs
an explicit algorithm/validation/error/ownership boundary.

## Commands and target qualification

`command_groups` maps every installed help command. CLI command-name parity is
insufficient: verify options, outputs, dependency inputs, exit statuses,
failure atomicity and cleanup. Backend tool invocation can be an explicit
primitive; the Cell driver/build/package algorithms still must be Cell.

| Zig command group | Current Cell subset | Complete contract |
| --- | --- | --- |
| build/fetch/init | C executable recipe only; package/build graph absent. | Declarative graph, initialization, dependency fetching/cache hashes, manifest compatibility and reproducibility. |
| build-exe/build-lib/build-obj/test-obj | C-only executable build; other artifact interfaces absent. | Executable/static/shared library/object/test object outputs, linking/exports/debug info and native/cross ABI validation. |
| test/run | C-target directory-program driver and temporary run recipe. | Language test discovery, failures/skips, modes/filtering, argument/exit forwarding and resource cleanup. |
| ast-check/fmt/reduce | Parse/type/borrow check and AST dump; formatter/reducer absent. | Parse-only diagnostics, canonical formatting/idempotence and semantics preservation, minimized reproducer retaining its failure. |
| translate-c/cc/c++ | Partial foreign C ABI/host backend invocation; corresponding user tools absent. | Translation/foreign type semantics, flags/inputs/errors and qualified foreign compiler/backend boundaries. |
| ar/dlltool/lib/objcopy/objdump/ranlib/rc | Absent equivalent Cell tool interfaces. | Archive/import-library/resource/object transformations, formats, symbols, deterministic outputs and failure atomicity. |
| env/help/cache-cat/std/libc/targets/version/zen | Help/version and development inventory; other user-facing interfaces incomplete or absent. | Toolchain/cache introspection, SDK/libc/target manifests, current documentation discovery and accurate capability reporting. |

`--target=c|llvm|mlir` selects a backend today; it is not a Zig target triple.
The AAPCS64 classifier cannot establish Linux/Windows or other CPU ABI support.
Current primitive parameters pass by value in every ownership mode, including
`exclusive` ([lowering](../src/cell/codegen/lower.zig), [ABI](../src/cell/abi.zig)).
A focused accepted program assigning 42 to an `exclusive Int` parameter leaves
the caller's original 37 unchanged on C/LLVM/MLIR. This is the explicit current
passing contract, not evidence of scalar pointer/write-through capability.
Qualification must distinguish this from aggregate exclusive references and
future raw pointer semantics.
Every claimed target needs resolved architecture/OS/ABI/CPU/features, layout,
runtime availability, object/linking and public ABI witnesses. Compare legal
target conditions against the installed manifest; do not assume every Cartesian
architecture/OS combination is legal. Cross-compilation and native execution
are distinct receipts. Native macOS/Linux/Windows qualification is mandatory,
with separate WASM/WASI/freestanding/GPU contracts where claimed.

## Self-hosting, LSP, highlighting and editor

Compiler sources are currently Zig; the only registered Cell stdlib source is
the bodyless prelude. Cell compiler/analysis/evaluator/library algorithms must
be executable Cell implementations before strict self-hosting can be claimed.
Compare bootstrap and successive Cell-built compiler generations against
identical declared inputs and semantic/value/diagnostic/output fixtures.

No Cell-written LSP/editor/highlighter implementation was found in the current
`src`, `stdlib` and `tools` surface. Language coverage requires these consumers
to handle every implemented construct and its incomplete/error states, using
the shared semantic analysis rather than a divergent parser/checker.

The current official LSP specification is 3.18. It defines JSON-RPC messaging,
byte-counted framing and capability exchange; the implementation must pin its
complete protocol source and advertise only supported features.
[Official specification](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.18/specification.md).

Qualification must include framing/JSON errors and partial reads, lifecycle
and negotiated capabilities, document revisions/position encodings, stale
results and cancellation, diagnostics, completion/navigation/reference/rename
behavior and semantic token synchronization. Highlighting needs both lexical
fallback on malformed source and semantic ownership/type/symbol classification.
The terminal editor needs edit/undo/redo, loading/saving/failure preservation,
Unicode navigation/display, resize/input handling and live analysis integration.
These are acceptance requirements, not implementation approval or claims that
every optional LSP feature has been promised. Exercise the actual Cell-built
server/editor on all three native hosts; screenshots or protocol mocks cannot
replace executable persistence, cancellation and editing evidence.

## Remaining proof gaps

Semantic reachability/type constraints and per-target conditions still need
resolution across the installed stdlib and builtin APIs. Family partitions are
discovery controls, not a substitute for operation-level qualification records.
The full `comptime` interpreter, library algorithms, compiler migration,
language tooling and native qualification remain unfinished. Existing approved
code receipts and the [Proposed full comptime design](superpowers/specs/2026-10-08-full-comptime-interpreter-design.md)
are kept separate from this acceptance map.
