# Full Cell compile-time interpreter

Status: Proposed. Donald selected full interpreter design before a scalar
constant implementation on 2026-10-08. This document requests design review;
it is not an implementation plan or a claim of current language support.

## Intent and acceptance

Provide Zig-master-equivalent compile-time capabilities while preserving
Cell's syntax and ownership contracts. The installed reference is Zig
`0.18.0-dev.120+9fe22a29b`, its local language reference and the reproducible
inventory described in [ZIG-PARITY.md](../../ZIG-PARITY.md).

Compile-time execution must support ordinary Cell functions, control flow,
mutation, aggregate construction, type values, reflection and generic
specialization. Required compile-time execution produces a value or a source
diagnostic; it never silently becomes runtime execution. Language operations
have one checked semantic contract across phases and backends.

The compiler, evaluator, analysis and libraries ultimately reside in Cell.
A Zig bootstrap implementation is a migration stage. C runtime or host
compiler calls must not become permanent evaluator implementations. LSP
requests use the same analysis/evaluation services with cancellation and
bounded resources. Native macOS/Linux/Windows receipts remain required.

“Full” describes the intended subsystem and acceptance contract. Integer
constants alone do not satisfy it. Missing language constructs are explicit
prerequisites within this design's implementation program, not exclusions
from the user's parity goal.

## Current evidence and alternatives

The current AST has no compile-time expression, parameter phase, type value
or generic declaration representation ([ast.zig](../../../src/cell/ast.zig)).
The checker returns expression types without retaining a durable checked
expression product ([typecheck.zig](../../../src/cell/typecheck.zig)).
Existing [HIR](../../../src/cell/hir.zig) has typed slots and useful control
flow, but tolerates unresolved values and inserts C runtime calls for String
conversion, indexing and list construction. It is backend lowering, not a
safe compile-time execution contract.

| Approach | Tradeoff |
| --- | --- |
| AST interpreter with side tables | Smaller initial bridge; repeats resolution and conversion logic over pointer-based, untyped nodes. Type-producing evaluation still requires a semantic request system. |
| Execute current HIR | Reuses slots and branches; must first remove unresolved values, runtime/ABI coupling and cleanup artifacts. It occurs too late to produce generic types. |
| Strict checked semantic representation, shared by evaluator and backend lowering | More foundational work; explicit types, phase and ownership make one contract reusable for compiler, LSP and Cell self-hosting. Recommended. |

Reuse existing place/slot/control-flow concepts, rather than introducing
another ownership policy. Keep current backend gates passing throughout the
migration; route each construct through the shared representation only after
semantic equivalence is demonstrated.

## Surface language proposal

Add a `comptime` phase qualifier, orthogonal to ownership. These examples are
proposed syntax, not accepted programs today:

```cell
pub const copy answer: Int = comptime fib(10)

fn identity(comptime copy T: Type, copy value: T) -> T {
    return value
}

pub fn main() {
    let copy value: Int = identity(Int, answer)
    let copy generated: Int = comptime {
        var copy n: Int = 0
        while n < 4 { n = n + 1 }
        n
    }
}
```

`comptime expression` forces evaluation. `comptime { ... }` makes the block's
bindings and selected control flow compile-time; its tail is its value.
`comptime let` and `comptime var` request compile-time local bindings outside
such a block. A `comptime` parameter must receive a known value and is erased
from the runtime signature. Ordinary functions can execute in either phase.
`const` declarations require known initializers; ownership spelling and type
annotations follow existing Cell binding conventions. Immutable does not
mean implicitly copyable for resource-bearing values.

`Type` is a compile-time-only value category. Existing type names are values
only where a type value is expected; runtime attempts to store or pass a
`Type` fail. Types produced by evaluation can appear in annotations, function
signatures and instantiated declarations. Existing names, module visibility,
nominal identity, shadowing, and interface/body pairing remain authoritative.
Adding the new keyword requires an explicit diagnostic for an existing
identifier named `comptime`; no silent reinterpretation is allowed.

Use the ordinary module-qualified call syntax for compiler intrinsics:
`use std.meta`, then `meta.type_of(value)`, `meta.type_info(T)`,
`meta.type_from_info(info)`, `meta.field(value, name)`,
`meta.has_decl(T, name)`, `meta.compile_error(message)`,
`meta.compile_log(value)`, and `meta.set_eval_branch_quota(n)`.
`meta.instantiate(recipe)` explicitly creates a fresh owner from a frozen
resource recipe; it is never an implicit copy of an owning binding.
`use std.build` supplies `build.embed_file(path)` and target metadata.
Intrinsic identity belongs to compiler-provided canonical declarations;
a user function with the same spelling cannot acquire compiler privileges.
These source modules and the declared intrinsic registry must be inspectable.

The parity matrix must map every installed reflection/type-construction
builtin to a Cell capability and fixture. The examples above name foundational
interfaces, not a closed enumeration of reflection functionality.

## Shared semantic architecture

`SemanticProgram` owns stable module, declaration, type, binding and operation
identities plus source provenance. Canonical declaration identity comes from
the existing module graph, not a short name or emitted C symbol. `TypeStore`
interns complete structural types while preserving nominal declaration
identity. A generated nominal type is identified by its declaration and
specialization, not merely an identical field list.

`analyze(declaration, specialization)` produces strict checked operations or
diagnostics. Each operation carries its type, phase, source span, resolved
references and ownership effect. Examples include conversion, index,
aggregate construction, call, move, borrow, retain and release. These remain
language operations; the backend later selects runtime symbols and ABI
representations. Error recovery may contain an unknown type, but executable
operations and materialized constants may not.

Analysis and evaluation cooperate through requests. Type expressions may
request evaluation, which may analyze a function instance or request a type.
Requests distinguish declaration identity, signature, body, type identity,
type completion, layout and value evaluation. State is unseen, pending,
completed or failed. Publish stable function/type identities and explicit
signatures before analyzing bodies. Recursive calls reuse those identities;
pointer-recursive nominal types can reference an incomplete type identity
without requesting its by-value layout. A cycle that requires an unavailable
completed value/layout/signature produces a diagnostic; an infinitely sized
by-value type is rejected. Inferred recursive signatures require an explicit
annotation when inference cannot complete. Ordinary recursive execution uses
interpreter frames and the evaluation budget, rather than declaration-cycle
failure. This rule applies to mutually recursive declarations too.

Semantic instance identities contain canonical declaration identity, explicit
compile-time arguments, runtime argument types, target and semantic version.
Forced evaluation has a separate identity containing every known argument
value that influences analysis, including ordinary function arguments. Keys
preserve nominal type identity and must not equate distinct mutable allocations.
Initially do not memoize arbitrary calls with mutable/ref/ARC arguments;
cache completed semantic instances and frozen immutable results with explicit
dependencies. Failed and cancelled requests never become completed cache entries.

Input dependencies are discovered during analysis/evaluation. Cache lookup
uses a preliminary request identity and stored dependency manifest, validating
all recorded inputs against one immutable compilation/revision snapshot before
reuse. Changed input starts a new snapshot; it does not mutate types already
published within an existing snapshot. Diagnostic logs are cached ordered
events replayed once per consuming top-level request, rather than silently
disappearing on a hit. Semantic identity and cache validity are separate.

Generated nominal identity includes generator source site, semantic instance,
captured compile-time environment and deterministic creation ordinal. Repeated
resolution of the same declaration request returns its published identity;
pure type-producing calls with the same canonical known arguments reuse a
stable type request identity, independent of the caller's source site or cache
eviction. Creation ordinals are local to that request's deterministic execution
path, not a global execution counter. Distinct generator sites, captured
environments or creation positions yield distinct nominal types even with
identical fields. Canonical structural constructors such as arrays
and pointer types instead intern by their full structural descriptor.

Each frame has an explicit phase environment: known compile-time values,
runtime slots, and unavailable/error states. A forced call binds all provided
arguments as known values; an ordinary runtime call binds only explicitly
compile-time parameters as known values. A branch is compile-time selected
exactly when its guard evaluates to a known Boolean/tag in that environment.
Writing a compile-time expression as a runtime call argument does not by
itself make the whole call compile-time.

Syntax and lexical binder structure are checked for the entire declaration.
For compile-time-selected branches, name resolution, type-dependent analysis
and ownership checking are performed only on the selected branch after
specialization, allowing a branch to reference operations/declarations
available only for its selected type/target. Runtime branches analyze
both paths and retain current ownership merge rules. Unselected branches
cannot expose declarations into the surrounding scope.
Checked semantic templates retain nonexecutable deferred region requests for
branches whose analysis depends on known values. The interpreter asks analysis
to check the selected region under its phase environment before executing any
operation in it. A deferred region is not an unresolved executable operation.
Runtime body requests check both unknown-guard regions; they never reuse a
body pruned for one forced invocation. Known short-circuit operands and match
guards use the same selection rule. Runtime control flow cannot mutate a
compile-time binding when its execution is not statically known.

## Interpreter and value model

`evaluate(request)` takes a checked entry/template, typed arguments, target, input
provider, resource budget and cancellation token. Its outcome is a value,
source diagnostic, cancellation or resource-limit error. Internally, explicit
control-flow outcomes distinguish ordinary values, return, labelled break and
continue; a return cannot escape a forced block into its runtime caller.

The interpreter supports short-circuit Boolean operators, guarded matches,
block tails, calls/recursion, loops, assignments, field/index operations,
structs, arrays/lists, vectors, enums with payloads, Optional and Result.
Features absent from today's AST/type system require their corresponding
language/type/ownership design and checked operations before evaluation.
The full acceptance matrix includes iteration, payload patterns, error
propagation, defer and generic/type-generating functions; it must not label
these implemented merely because an interpreter tag exists.

Checked calls carry explicit semantic parameter passing, separately from
target ABI representation. Preserve today's primitive by-value passing in
every ownership mode, including `exclusive Int`; mutation of that parameter
does not write into its caller. Aggregate exclusive references retain their
referent identity. Neither the evaluator nor the backend may infer universal
write-through from an ownership keyword alone. A future change to scalar
reference semantics requires a deliberate language/ABI migration and fixtures.

Values are explicit tagged data: arbitrary-precision compile-time integer,
compile-time float, fixed-width numeric, Boolean, enum/tagged value, aggregate,
function, type, abstract reference and resource handle. Preserve literal
spelling until numeric parsing into this model: current AST `i64`/`f64`
storage cannot represent the intended numeric parity. Numeric conversion,
overflow, shift, NaN and rounding contracts are target-aware. Host Zig integer
or floating arithmetic is not the specification. The eventual Cell arithmetic
implementation must reproduce the same answers from serialized fixtures.

The value model and evaluator require no physical C ABI layouts. Layout
reflection uses a target description and a layout service, independently of
host pointer size and ABI. Arbitrary-width integers, fixed arrays, slices,
pointers, address spaces, alignment, packed types and vectors must be reflected
when those language capabilities are implemented; unknown layout is an error.

## Compile-time memory and Cell ownership

`ComptimeHeap` uses allocation identities and generation counters. A place
consists of allocation identity and field/index projections. References carry
access mode and lifetime; never expose a host pointer. Frames own binding
slots. Move invalidates the source; initialization/revival follows Cell's
checked ownership rules. ARC uses abstract handles and deterministic retain/
release effects. Scope exit, jumps, returns and failure paths release owned
interpreter resources, including allocations created during failed analysis.

Static ownership checking remains authoritative, including current R8 borrow
escape refusals and named-loan NLL boundaries. Executed operations also check
generation, initialization, bounds and access invariants. Compile-time
execution does not grant permission to accept a borrow that runtime Cell
refuses. Specializations are checked after type/branch selection, with source
and specialization provenance attached to diagnostics.

`freeze(value)` produces an immutable `ConstantGraph` only if the value has no
runtime dependence, frame-local reference or mutable escaping alias. A
compile-time pointer can become a runtime relocation only when its referent
is stable immutable promoted storage and its type/ownership contract permits
that reference. Cyclic or resource-bearing graphs require explicit supported
materialization; unsupported forms fail rather than serialize host addresses.
Freeze is an atomic deep copy into program-owned immutable storage with
allocation/projection relocation remapping. Publish the graph only after
every edge and ownership constraint passes validation. On success, original
frame allocations remain frame-owned and are cleaned normally; on failure,
discard the unpublished graph and preserve original cleanup responsibility.
Published graph references therefore survive frame teardown without borrowing
the original evaluator allocation. Copying during freeze is compiler storage
management, not an implicit source-language resource copy.

Deduplicating immutable constant bytes is distinct from sharing an owning
buffer. Scalar/type/immutable-view constant uses copy their value or stable
reference under existing copy rules. A resource-bearing module constant is a
compile-time-only `Frozen<T>` recipe, with its annotation specifying payload
`T`; using it directly in an owning runtime context is rejected. An explicit
`meta.instantiate(recipe)` operation produces a fresh owning graph on each
invocation. An explicit ARC conversion may box that fresh owner using checked
retain/release rules. Compile-time code can inspect a frozen recipe immutably
or explicitly instantiate it into evaluator-owned storage; it cannot move the
recipe as if it were an owner. No general borrowed-return or stored-borrow
exception is introduced for constants: R8 remains binding. Runtime immutable
views require a supported existing view representation and promoted storage
contract; otherwise refuse. Multiple instantiations cannot acquire owners of
one allocation through constant interning. This policy must be visible in
checked operations and borrow checking, not a backend-only duplication trick.
Every backend must implement a materialization case or refuse it before
emitting any output.

## Effects, budgets and diagnostics

Allow deterministic operations on evaluator-owned memory. Reject ordinary
extern calls, OS I/O, clocks, randomness, process creation, networking and
runtime global mutation during evaluation. Declared compiler services provide
read-only build inputs such as embedded bytes. Canonical path, content hash
and target/configuration become dependency records; undeclared input access
fails. Compile logs are ordered diagnostic events, not arbitrary host output.

Default limits per top-level request: 1000 backward branches, 1,000,000
operations, 256 call frames, 64 MiB live evaluator storage, 100,000 live
allocations and 10,000 specializations. All are independently checked and
configurable by the invoking compiler/analysis service. Backward-branch quota
can be raised explicitly through `meta.set_eval_branch_quota`; it cannot override
host resource caps. Nested calls, semantic requests and specializations share
the top-level budget instead of resetting it. Charge numeric/type construction,
dependency input bytes, generated semantic nodes, diagnostics and cache growth
before allocating; a huge single integer shift/type construction must not
bypass the memory cap merely because it counts as one operation. Limits and
target form part of the request configuration.
Charge operand-size-dependent work across arithmetic, layout, interning,
freezing, hashing and input services to the same operation budget. Long
primitive loops and input reads poll cancellation at least every 1024 units of
work or 64 KiB of input. Declared input services enforce byte limits before
reading/allocation. Program-owned results and caches have a separate default
256 MiB service cap; evict unused snapshot/cache entries before admitting new
storage, or report a resource-limit diagnostic when active results prevent
eviction. Cancelled/obsolete LSP revisions release their temporary request
storage; pinned results are charged until their snapshot is released.
Cancellation is checked at request dispatch, calls, backward branches and
allocation. Compiler and LSP must never return a partial value on exhaustion.

Diagnostics identify the failing operation, forcing site, declaration/input,
and bounded call/instantiation stack. Include errors for unknown runtime
values, forbidden effects, invalid casts/layout, arithmetic faults, invalid
memory access, dependency cycles and each exceeded limit. Sort diagnostics
deterministically by request/source identity, independent of worker completion
order. Failed requests roll back their temporary storage and cache entries.

## Parity, integration and self-hosting qualification

Create explicit contracts from the installed Zig inventory for comptime
expressions/variables/parameters, type values, type creation/reflection,
specialization, inline control flow, numeric operations, pointer/aggregate
constants, target/layout queries, compiler diagnostics, branch quota and
declared input services. For each: accepted program, exact result, refused
program, exact failure class, and platform/backend qualification.
Capabilities not yet implemented remain Proposed or Partial in the matrix.

Compare ordinary runtime execution and compile-time evaluation of the same
pure function. Add differential Zig/Cell fixtures where semantics correspond;
record deliberate Cell ownership/syntax differences instead of treating
identical source spelling as parity. Exercise runtime-dependent refusal,
unselected type-specific branches, recursive functions and declaration cycles,
module privacy/shadowing, every jump/cleanup path, borrow escape, nested
aggregate mutation, alias generations, numeric boundaries and constant
materialization. Each resource limit and cancellation needs deterministic
failure/cleanup tests. Run the repository's full gate after each integration.
Include direct/mutual function recursion, pointer-recursive generated types,
impossible by-value layout and cyclic constants. Evaluate the same Boolean
branching function with both values and subsequently request its runtime body.
Test repeated type creation at one site versus distinct sites, dependency
snapshot changes, log replay, direct repeated consumption of a frozen recipe
(refused), explicit repeated instantiation (independent owners), relocation
survival after frame cleanup and failed freeze cleanup. Adversarial numeric
widths, deep types, huge inputs and cancelled/repeated LSP revisions must stay
within the shared request and service caps.

Compare serialized semantic/value/diagnostic fixtures across Zig bootstrap
and the Cell implementation. Then compile successive Cell compiler generations
from identical declared inputs, verify normalized semantic/output identity,
and run native macOS/Linux/Windows gates against the same manifests.
No permanent bridge delegates evaluation, reflection or specialization back
to Zig. Backend/OS primitives remain explicit, minimal interfaces.

## Review boundary

Review the semantic representation, proposed syntax, specialization/selected
branch rules, numeric model, ownership/constant promotion, effect services and
budgets together. Approval permits writing the detailed implementation plan;
it does not certify any feature or authorize publication. No commits, pushes,
new dependencies or deployment changes are part of this design.
