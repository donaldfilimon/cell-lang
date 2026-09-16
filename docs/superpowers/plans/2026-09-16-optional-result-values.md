# Optional and Result values Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cell programs can build `T?` and `Result<T, E>` values with `Some`/`None`/`Ok`/`Err` and inspect them in `match`, for scalar payloads, through the C backend.

**Architecture:** Four new keywords lex; the parser produces one new expression kind (`wrap`) and one new pattern kind (`wrap_pattern`); the type checker types constructors and patterns against the existing `optional`/`result` types; borrowck treats payloads as `copy` reads; the C backend lowers onto the runtime's existing `cell_opt_*` and `cell_ok_*` helpers plus one new `cell_err`; the HIR (LLVM and MLIR) refuses with `cannot lower`.

**Tech Stack:** Zig master (`~/.zvm/bin/zig`, `0.17.0-dev.2131+d08989840`), C11 runtime compiled by `cc` at `-Wall -Wextra -Werror`, `tools/check.sh` as the gate.

**Spec:** `docs/superpowers/specs/2026-09-16-optional-result-and-prelude-design.md`, section B.

## Global Constraints

- Every `zig` command takes `-Dswift=false`; a failed build leaves the old `zig-out/bin/cell` in place, so read the build's exit code before running the binary.
- Never `cmd | tail` a command whose status matters; redirect to a log and `echo "EXIT: $?"`.
- `zig build test` does not accept `--test-filter`; filter with `zig test src/cell/<file>.zig --test-filter "<name>"` and confirm the NAMED test appears in the output (a typo'd filter still exits 0).
- No em dashes anywhere (source, docs, commit messages). Zig idioms as found (`std.ArrayList(T) = .empty`, allocator-passing methods).
- Payloads this slice: `Int`, `Int32`, `UInt`, `Float`, `Float32`, `Bool`, `Byte`; `E` is `Int32` or a payload-free enum. Everything else is refused with the messages given in Task 3.
- Work on `main` in `~/dev/active/cell-lang`; commit after each task; `tools/check.sh` at the end of Task 8 must read `verdict: clean` from its log.
- Exhaustive `switch`es over `ast.Expr.Kind` and `ast.Pattern.Kind` exist in several files. After Task 2 the build fails until every one has an arm for `.wrap` / `.wrap_pattern`; each task below names the arms it owns, and any switch the compiler names that no task lists gets the arm `.wrap => |w| <treat like .unary with an optional operand>` or `.wrap_pattern => <treat like .enum_variant>`.

---

### Task 1: Lexer keywords

**Files:**
- Modify: `src/cell/lexer.zig` (the `TokenKind` enum after `kw_copy`, the `keyword` table after `"copy"`, and the tests at the end)
- Modify: `docs/SPEC.md` section 2.5 (add the four words to the keyword list, not the reserved list)

**Interfaces:**
- Produces: `TokenKind.kw_some`, `.kw_none`, `.kw_ok`, `.kw_err`.

- [ ] **Step 1: Write the failing test** (append to `src/cell/lexer.zig`)

```zig
test "Some, None, Ok and Err lex as keywords, not identifiers" {
    const words = [_][]const u8{ "Some", "None", "Ok", "Err" };
    const kinds = [_]TokenKind{ .kw_some, .kw_none, .kw_ok, .kw_err };
    for (words, kinds) |word, kind| {
        var lex = Lexer.init(word, "t.cell");
        var tokens = try lex.tokenizeAll(std.testing.allocator);
        defer tokens.deinit(std.testing.allocator);
        try std.testing.expectEqual(kind, tokens.items[0].kind);
    }
    // A user identifier that merely starts the same way is untouched.
    var lex = Lexer.init("Something", "t.cell");
    var tokens = try lex.tokenizeAll(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);
    try std.testing.expectEqual(TokenKind.ident, tokens.items[0].kind);
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `zig test src/cell/lexer.zig --test-filter "lex as keywords, not identifiers" 2>&1 | tail -5`
Expected: compile error, `kw_some` is not a member of `TokenKind`.

- [ ] **Step 3: Add the token kinds and table rows**

In the `TokenKind` enum, directly after `kw_copy,`:

```zig
    // Value constructors for `T?` and `Result<T, E>` (SPEC 3.2, 3.4).
    // Keywords, so a user enum can never declare a variant with one of
    // these names and the uppercase-is-a-variant pattern rule needs no
    // special case.
    kw_some,
    kw_none,
    kw_ok,
    kw_err,
```

In `fn keyword`, directly after `.{ "copy", .kw_copy },`:

```zig
            .{ "Some", .kw_some },
            .{ "None", .kw_none },
            .{ "Ok", .kw_ok },
            .{ "Err", .kw_err },
```

- [ ] **Step 4: Run the test and the whole lexer file**

Run: `zig test src/cell/lexer.zig 2>&1 | tail -3`
Expected: the named test appears with `OK` and `All N tests passed`.

- [ ] **Step 5: SPEC 2.5**

In `docs/SPEC.md` section 2.5, add `Some`, `None`, `Ok`, `Err` to the keyword block (the one that lists `fn let var ...`), with one sentence: "`Some`, `None`, `Ok` and `Err` are keywords since 2026-09-16 so that they can never collide with a user enum's variants (section 9)."

- [ ] **Step 6: Commit**

```bash
git add src/cell/lexer.zig docs/SPEC.md
git commit -m "lexer: Some, None, Ok and Err are keywords"
```

---

### Task 2: AST and parser

**Files:**
- Modify: `src/cell/ast.zig` (`Expr.Kind`, `Pattern.Kind`)
- Modify: `src/cell/parser.zig` (`parsePrimary`, `parsePattern`, tests)

**Interfaces:**
- Produces:
  - `ast.Ctor = enum { some, none, ok, err }` (top level in `ast.zig`).
  - `Expr.Kind.wrap: struct { ctor: Ctor, operand: ?*Expr }`; `operand` is null exactly for `.none`.
  - `Pattern.Kind.wrap_pattern: struct { ctor: Ctor, binding: ?[]const u8 }`; `binding` null means `_` or `None`.

- [ ] **Step 1: Write the failing parser tests** (append to `src/cell/parser.zig`, next to "each match pattern form parses")

```zig
test "Some/None/Ok/Err parse as wrap expressions" {
    var tp = try parseForTest(
        \\pub fn f() -> Int {
        \\  let a: Int? = Some(1)
        \\  let b: Int? = None
        \\  let c: Result<Int, Int32> = Ok(2)
        \\  let d: Result<Int, Int32> = Err(3)
        \\  return 0
        \\}
    );
    defer tp.deinit();
    const body = tp.module.items[0].fn_def.body;
    const a = body[0].kind.let.value.?.kind.wrap;
    try std.testing.expectEqual(ast.Ctor.some, a.ctor);
    try std.testing.expectEqual(@as(i64, 1), a.operand.?.kind.int);
    const b = body[1].kind.let.value.?.kind.wrap;
    try std.testing.expectEqual(ast.Ctor.none, b.ctor);
    try std.testing.expect(b.operand == null);
    try std.testing.expectEqual(ast.Ctor.ok, body[2].kind.let.value.?.kind.wrap.ctor);
    try std.testing.expectEqual(ast.Ctor.err, body[3].kind.let.value.?.kind.wrap.ctor);
}

test "Some/None/Ok/Err parse as wrap patterns with a binding or a wildcard" {
    var tp = try parseForTest(
        \\pub fn f(copy o: Int?) -> Int {
        \\  return match o {
        \\    Some(x) => x,
        \\    Some(_) => 1,
        \\    None => 0,
        \\  }
        \\}
    );
    defer tp.deinit();
    const m = onlyStmt(tp.module).kind.return_stmt.?.kind.match_expr;
    const p0 = m.arms[0].pattern.kind.wrap_pattern;
    try std.testing.expectEqual(ast.Ctor.some, p0.ctor);
    try std.testing.expectEqualStrings("x", p0.binding.?);
    const p1 = m.arms[1].pattern.kind.wrap_pattern;
    try std.testing.expect(p1.binding == null);
    const p2 = m.arms[2].pattern.kind.wrap_pattern;
    try std.testing.expectEqual(ast.Ctor.none, p2.ctor);
    try std.testing.expect(p2.binding == null);
}

test "malformed wrap forms are parse errors" {
    // `Some` needs parentheses; `Ok()` needs an operand; a nested
    // constructor inside a pattern is refused; `None(x)` is refused.
    const bad = [_][]const u8{
        "pub fn f() -> Int? { return Some }",
        "pub fn f() -> Result<Int, Int32> { return Ok() }",
        "pub fn f(copy o: Int?) -> Int { return match o { Some(Some(x)) => 1, _ => 0 } }",
        "pub fn f() -> Int? { return None(1) }",
    };
    for (bad) |src| {
        var lex = Lexer.init(src, "t.cell");
        var tokens = try lex.tokenizeAll(std.testing.allocator);
        defer tokens.deinit(std.testing.allocator);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var p = Parser.init(arena.allocator(), tokens.items);
        try std.testing.expectError(error.ParseFailed, p.parseModule());
    }
}
```

If `parseForTest`, `onlyStmt`, `Parser.init` or `parseModule` are spelled differently in the file, use the file's spelling (read the existing "each match pattern form parses" test and the test right after it for the exact helper names); do not invent new helpers.

- [ ] **Step 2: Run to see them fail**

Run: `zig test src/cell/parser.zig --test-filter "wrap" 2>&1 | tail -5`
Expected: compile error, no field `wrap`.

- [ ] **Step 3: AST**

In `src/cell/ast.zig`, above `pub const Expr = struct`:

```zig
/// The four value constructors for `T?` and `Result<T, E>` (SPEC 3.2, 3.4).
pub const Ctor = enum { some, none, ok, err };
```

In `Expr.Kind`, after `match_expr`:

```zig
        /// `Some(e)`, `None`, `Ok(e)`, `Err(e)`. `operand` is null exactly
        /// for `None`.
        wrap: struct { ctor: Ctor, operand: ?*Expr },
```

In `Pattern.Kind`, after `bool`:

```zig
        /// `Some(x)`, `Some(_)`, `None`, `Ok(x)`, `Err(x)`. `binding` is
        /// null for `_` and for `None`.
        wrap_pattern: struct { ctor: Ctor, binding: ?[]const u8 },
```

Update the `Pattern` doc comment ("Enum variants carry no payload ... no subpatterns to nest") to add: "A wrap pattern carries at most one binding; nested patterns are refused by the parser."

- [ ] **Step 4: Parser, expressions**

In `parsePrimary`, directly before `if (self.match(.ident)) {`:

```zig
        if (self.match(.kw_none)) {
            if (self.check(.l_paren)) return self.fail("'None' takes no operand");
            return self.expr(.{ .wrap = .{ .ctor = .none, .operand = null } }, start);
        }
        if (self.matchCtor()) |ctor| {
            try self.expect(.l_paren);
            const saved = self.no_struct_lit;
            self.no_struct_lit = false;
            const inner = try self.parseExpr();
            self.no_struct_lit = saved;
            try self.expect(.r_paren);
            const p = try self.allocator.create(ast.Expr);
            p.* = inner;
            return self.expr(.{ .wrap = .{ .ctor = ctor, .operand = p } }, start);
        }
```

Add the helper next to `parseOwnership`:

```zig
    /// `Some`, `Ok` or `Err` (the three constructors that take an operand).
    fn matchCtor(self: *Parser) ?ast.Ctor {
        if (self.match(.kw_some)) return .some;
        if (self.match(.kw_ok)) return .ok;
        if (self.match(.kw_err)) return .err;
        return null;
    }
```

- [ ] **Step 5: Parser, patterns**

In `parsePattern`, directly before `if (self.match(.ident)) {`:

```zig
        if (self.match(.kw_none)) {
            return self.patternNode(.{ .wrap_pattern = .{ .ctor = .none, .binding = null } }, start);
        }
        if (self.matchCtor()) |ctor| {
            try self.expect(.l_paren);
            if (!self.match(.ident)) return self.fail("expected a binding or '_' inside the pattern");
            const name = self.prev().lexeme;
            const binding: ?[]const u8 = if (std.mem.eql(u8, name, "_")) null else name;
            try self.expect(.r_paren);
            return self.patternNode(.{ .wrap_pattern = .{ .ctor = ctor, .binding = binding } }, start);
        }
```

- [ ] **Step 6: Build and add the missing switch arms the compiler names**

Run: `zig build -Dswift=false > /private/tmp/b.log 2>&1; echo "EXIT: $?"; grep -n 'switch must handle\|error:' /private/tmp/b.log | head -20`

The compiler lists every exhaustive switch. Tasks 3, 4, 5 and 7 own the arms in `typecheck.zig`, `borrowck.zig`, `hir.zig` and `codegen.zig`; for THIS task add only the arms in files no later task owns, and leave the rest failing until their task (or, if you are executing the plan alone, do Tasks 3 to 7's arms now and keep each task's tests). The arms are, per file:

- `src/cell/hir.zig` `lowerExpr`: `.wrap => |w| { _ = w; try self.cannotLower(e.span, "optional and Result values are not lowered by the IR backends"); return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "wrap" }); }`
- `src/cell/hir.zig` `lowerPattern`: `.wrap_pattern => { try self.cannotLower(p.span, "optional and Result patterns are not lowered by the IR backends"); return .{ .kind = .wildcard, .span = p.span }; }`
- `src/cell/codegen.zig` `exprUses`: `.wrap => |w| if (w.operand) |o| exprUses(o, name) else false,`
- `src/cell/codegen.zig` `collectIdents`: `.wrap => |w| if (w.operand) |o| try collectIdents(arena, o, set) else false,` (match the function's return contract; read its `.unary` arm and copy its shape)
- Any other switch the compiler names: `.wrap` behaves like `.unary` with an optional operand; `.wrap_pattern` behaves like `.enum_variant` (a non-default pattern that reads the scrutinee).

- [ ] **Step 7: Run the parser tests**

Run: `zig test src/cell/parser.zig 2>&1 | tail -3`
Expected: the three named tests `OK`, `All N tests passed`.

- [ ] **Step 8: Commit**

```bash
git add src/cell/ast.zig src/cell/parser.zig src/cell/hir.zig src/cell/codegen.zig
git commit -m "parser: Some/None/Ok/Err expressions and match patterns (wrap, wrap_pattern)"
```

---

### Task 3: Type checker

**Files:**
- Modify: `src/cell/typecheck.zig` (`checkExpr`, the `.match_expr` arm, the `.let` arm, tests)

**Interfaces:**
- Consumes: `ast.Ctor`, `Expr.Kind.wrap`, `Pattern.Kind.wrap_pattern`.
- Produces: `Some(e)` types `optional(T)`; `None` types `optional(unknown)`; `Ok(e)` types `result(T, unknown)`; `Err(e)` types `result(unknown, E)`. Arm bindings are declared `copy` with the payload type.

- [ ] **Step 1: Write the failing tests** (append to `src/cell/typecheck.zig`, same `TestModule` style as the file's other tests)

```zig
test "Some carries its operand's type and None needs a declared slot" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() -> Int? {
        \\    let a: Int? = Some(1)
        \\    let b: Int? = None
        \\    let c = None
        \\    return a
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 4, 13, "'None' needs a declared optional type here");
}

test "Ok and Err are checked against the declared Result" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub enum IoError { Missing, Denied }
        \\pub fn f() -> Result<Int, IoError> {
        \\    let r: Result<Int, IoError> = Ok(1)
        \\    let e: Result<Int, IoError> = Err(IoError.Denied)
        \\    let bad: Result<Int, Int32> = Err("x")
        \\    let untyped = Ok(1)
        \\    return r
        \\}
    );
    try t.expectCount(2);
    try t.expectDiag(0, .err, 5, 35, "cannot initialize a binding of type Result<Int, Int32> with a value of type Result<Int, String>");
    try t.expectDiag(1, .err, 6, 19, "'Ok' needs a declared Result type here");
}

test "scalar payloads only" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(owned s: String) -> String? {
        \\    return Some(s)
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 12, "optional/Result payloads other than scalar primitives are not implemented");
}

test "wrap patterns bind the payload and need the matching scrutinee" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(copy o: Int?, copy r: Result<Int, Int32>, copy n: Int) -> Int {
        \\    let a = match o { Some(x) => x, None => 0 }
        \\    let b = match r { Ok(v) => v, Err(code) => 0 }
        \\    let c = match n { Some(x) => x, _ => 0 }
        \\    return a + b + c
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 4, 23, "pattern 'Some' needs an optional scrutinee, found Int");
}
```

Column numbers point at the offending expression or pattern; if a run reports a different column, read the diagnostic and correct the test's column, not the checker, unless the span is plainly wrong.

- [ ] **Step 2: Run to see them fail**

Run: `zig test src/cell/typecheck.zig --test-filter "Some carries" 2>&1 | tail -5`
Expected: compile error (missing `.wrap` arm) or a failing count.

- [ ] **Step 3: Helpers** (add near `listOf`)

```zig
    fn optionalOf(self: *Checker, inner: Type) CheckError!Type {
        const p = try self.arena().create(Type);
        p.* = inner;
        return .{ .optional = p };
    }

    fn resultOf(self: *Checker, ok: Type, err: Type) CheckError!Type {
        const o = try self.arena().create(Type);
        o.* = ok;
        const e = try self.arena().create(Type);
        e.* = err;
        return .{ .result = .{ .ok = o, .err = e } };
    }

    /// The payloads this slice admits (spec B.2): the scalar primitives.
    fn isScalarPayload(t: Type) bool {
        return switch (t) {
            .unknown, .int, .int32, .uint, .float, .float32, .boolean, .byte => true,
            else => false,
        };
    }

    /// `E` is an `Int32` code or a payload-free enum (spec B.2).
    fn isErrorPayload(t: Type) bool {
        return switch (t) {
            .unknown, .int32, .enum_type => true,
            else => false,
        };
    }
```

(`ResultType`'s field names are `ok` and `err`; confirm against `types.zig` line ~52 before compiling.)

- [ ] **Step 4: `checkExpr` arm** (after `.match_expr`)

```zig
            .wrap => |w| {
                const payload: Type = if (w.operand) |o| try self.checkExpr(o) else types.t_unknown;
                switch (w.ctor) {
                    .some => {
                        if (!isScalarPayload(payload)) {
                            try self.errf(expr.span, "optional/Result payloads other than scalar primitives are not implemented", .{});
                            return try self.optionalOf(types.t_unknown);
                        }
                        return try self.optionalOf(payload);
                    },
                    .none => return try self.optionalOf(types.t_unknown),
                    .ok => {
                        if (!isScalarPayload(payload)) {
                            try self.errf(expr.span, "optional/Result payloads other than scalar primitives are not implemented", .{});
                            return try self.resultOf(types.t_unknown, types.t_unknown);
                        }
                        return try self.resultOf(payload, types.t_unknown);
                    },
                    .err => {
                        // `Err("x")` is left typed as written so the declared
                        // slot reports the mismatch with both types named.
                        return try self.resultOf(types.t_unknown, payload);
                    },
                }
            },
```

- [ ] **Step 5: `.let` arm, the undeclared-slot rule**

In the `.let` arm, before `if (l.value) |*v| {`, add:

```zig
                if (annotated == null) {
                    if (l.value) |*v| {
                        if (v.kind == .wrap and v.kind.wrap.ctor != .some) {
                            const word = switch (v.kind.wrap.ctor) {
                                .none => "'None' needs a declared optional type here",
                                .ok => "'Ok' needs a declared Result type here",
                                .err => "'Err' needs a declared Result type here",
                                .some => unreachable,
                            };
                            try self.errf(v.span, "{s}", .{word});
                        }
                    }
                }
```

`Some(e)` needs no slot because its type is complete. A `return None` from a `-> T?` function and a call argument to a `T?` parameter are already checked by `accepts`, which is tolerant of `unknown`, so they need no rule.

- [ ] **Step 6: `.match_expr` arm, patterns**

Replace the `switch (arm.pattern.kind)` inside the arm loop with:

```zig
                    switch (arm.pattern.kind) {
                        .binding => |name| try self.declare(arm.pattern.span, name, .{
                            .ownership = .copy,
                            .mutable = false,
                            .ty = scrutinee,
                        }),
                        .wrap_pattern => |wp| {
                            const payload: ?Type = switch (wp.ctor) {
                                .some, .none => switch (scrutinee) {
                                    .optional => |inner| inner.*,
                                    .unknown => types.t_unknown,
                                    else => blk: {
                                        try self.errf(arm.pattern.span, "pattern '{s}' needs an optional scrutinee, found {s}", .{
                                            if (wp.ctor == .some) "Some" else "None",
                                            try self.typeName(scrutinee),
                                        });
                                        break :blk null;
                                    },
                                },
                                .ok, .err => switch (scrutinee) {
                                    .result => |r| if (wp.ctor == .ok) r.ok.* else r.err.*,
                                    .unknown => types.t_unknown,
                                    else => blk: {
                                        try self.errf(arm.pattern.span, "pattern '{s}' needs a Result scrutinee, found {s}", .{
                                            if (wp.ctor == .ok) "Ok" else "Err",
                                            try self.typeName(scrutinee),
                                        });
                                        break :blk null;
                                    },
                                },
                            };
                            if (wp.binding) |name| {
                                try self.declare(arm.pattern.span, name, .{
                                    .ownership = .copy,
                                    .mutable = false,
                                    .ty = payload orelse types.t_unknown,
                                });
                            }
                        },
                        else => {},
                    }
```

Also extend the guard restriction: change `if (arm.pattern.kind == .binding)` to

```zig
                        const binds = arm.pattern.kind == .binding or
                            (arm.pattern.kind == .wrap_pattern and arm.pattern.kind.wrap_pattern.binding != null);
                        if (binds) {
```

Read the `.binding` declare a few lines up: if the file declares it with `.ownership = .copy` already, keep that; the code above copies what the file does today.

- [ ] **Step 7: Run the typecheck tests**

Run: `zig test src/cell/typecheck.zig 2>&1 | tail -3`
Expected: all four new tests `OK`, `All N tests passed`.

- [ ] **Step 8: Commit**

```bash
git add src/cell/typecheck.zig
git commit -m "typecheck: type Some/None/Ok/Err and their match patterns, scalar payloads"
```

---

### Task 4: Borrow checker

**Files:**
- Modify: `src/cell/borrowck.zig` (`checkExpr` switch, `checkMatch`, `arcUniqueSource`, `ownedMoveSource`, `borrowSource` if it switches on kinds, tests)

**Interfaces:**
- Consumes: `Expr.Kind.wrap`, `Pattern.Kind.wrap_pattern`.
- Produces: no new rule. A wrap operand is a read; an arm binding is a fresh `copy` binding with `arm_origin = .temp`.

- [ ] **Step 1: Write the failing tests** (append near the R10 tests)

```zig
test "Some reads its operand and a wrap-pattern binding is a copy" {
    try expectAccepted(
        \\pub fn view(copy n: Int) -> Int;
        \\pub fn f(copy n: Int) -> Int {
        \\    let o: Int? = Some(n)
        \\    let m = view(n)
        \\    return match o { Some(x) => x + m, None => m }
        \\}
    );
    try expectRejectedWith(
        \\pub fn f(copy o: Int?) -> Int {
        \\    return match o {
        \\        Some(x) => { x = 1 x },
        \\        None => 0,
        \\    }
        \\}
    , "cannot assign to immutable binding 'x'");
}
```

- [ ] **Step 2: Run to see it fail**

Run: `zig test src/cell/borrowck.zig --test-filter "wrap-pattern binding" 2>&1 | tail -5`
Expected: compile error (missing arms) or a refusal.

- [ ] **Step 3: Arms**

`checkExpr` (the big switch near line 1660): `.wrap => |w| if (w.operand) |o| try self.checkExpr(o),`

`arcUniqueSource`: `.wrap => .not_arc,`

`ownedMoveSource`: `.wrap => .no_owned_place,`

`borrowSource` and any other exhaustive switch on `Expr.Kind` the compiler names: the arm that the `.binary` case uses (a value, never a place, never a borrow).

`checkMatch`, directly after the `if (arm.pattern.kind == .binding) { ... }` block:

```zig
            if (arm.pattern.kind == .wrap_pattern) {
                if (arm.pattern.kind.wrap_pattern.binding) |name| {
                    // The payload is a scalar copied out of the scrutinee
                    // (spec B.2), so it aliases nothing and owns nothing.
                    _ = try self.declare(.{
                        .id = 0,
                        .name = name,
                        .ownership = .copy,
                        .mutable = false,
                        .struct_name = null,
                        .decl_span = arm.pattern.span,
                        .arm_origin = .temp,
                        .arm_scrutinee = null,
                        .arm_scrutinee_binding = null,
                    });
                }
            }
```

- [ ] **Step 4: Run the borrowck tests**

Run: `zig test src/cell/borrowck.zig 2>&1 | tail -3`
Expected: the named test `OK`, `All N tests passed`.

- [ ] **Step 5: Commit**

```bash
git add src/cell/borrowck.zig
git commit -m "borrowck: wrap operands are reads, wrap-pattern bindings are copies"
```

---

### Task 5: Runtime helpers

**Files:**
- Modify: `runtime/cell_rt.h` (Result section, after `cell_ok_str`)
- Modify: `runtime/tests/test_cell_rt.c` (`test_result`)

**Interfaces:**
- Produces: `static inline cell_result_t cell_err(int32_t code)`; `static inline cell_result_t cell_ok_i32(int32_t v)` (stored in `value.i64`).

- [ ] **Step 1: Failing harness checks** (inside `test_result`, at its end)

```c
    cell_result_t e = cell_err(7);
    CHECK(!e.ok);
    CHECK(e.error_code == 7);
    CHECK(e.value.i64 == 0);
    cell_result_t i32 = cell_ok_i32(-5);
    CHECK(i32.ok);
    CHECK(i32.error_code == 0);
    CHECK((int32_t)i32.value.i64 == -5);
```

- [ ] **Step 2: Run to see it fail**

Run: `zig build test-runtime -Dswift=false > /private/tmp/rt.log 2>&1; echo "EXIT: $?"; grep -m3 'error' /private/tmp/rt.log`
Expected: EXIT 1, implicit declaration of `cell_err`.

- [ ] **Step 3: Implement** (in `cell_rt.h` after `cell_ok_str`)

```c
/** A failed Result carrying an error code; the payload is zeroed. */
static inline cell_result_t cell_err(int32_t code) {
    cell_result_t r;
    memset(&r, 0, sizeof(r));
    r.ok = false;
    r.error_code = code;
    return r;
}

/** An Int32 payload rides in the i64 slot; readers narrow with a cast. */
static inline cell_result_t cell_ok_i32(int32_t v) {
    cell_result_t r = cell_ok_unit();
    r.value.i64 = v;
    return r;
}
```

- [ ] **Step 4: Run**

Run: `zig build test-runtime -Dswift=false > /private/tmp/rt.log 2>&1; echo "EXIT: $?"`
Expected: EXIT 0 and no `FAIL` lines in the log.

- [ ] **Step 5: Commit**

```bash
git add runtime/cell_rt.h runtime/tests/test_cell_rt.c
git commit -m "runtime: cell_err and cell_ok_i32"
```

---

### Task 6: C backend types

**Files:**
- Modify: `src/cell/codegen.zig` (`CType` struct, `lowerType`'s `.optional` and `.result` arms, `applyOwnership`, `pointerTo`)

**Interfaces:**
- Produces: `CType.payload: ?*const CType` (the `T` of `T?` or the ok type of `Result<T, E>`) and `CType.err_payload: ?*const CType` (the `E`), both preserved by `applyOwnership` and `pointerTo` exactly as `elem` is.
- Produces: `fn optBase(ty: CType) []const u8` returning the instance base (`cell_opt_i64` for text `cell_opt_i64_t`).

- [ ] **Step 1: Failing test**

```zig
test "an optional and a Result type carry their payload types" {
    var e = try emitSource(
        \\pub enum E { A, B }
        \\pub fn f(copy o: Int32?, copy r: Result<Byte, E>) -> Int { return 0 }
    );
    defer e.deinit();
    const o = try e.gen.lowerType(&e.module.items[1].fn_def.params[0].ty, .copy);
    try std.testing.expectEqualStrings("cell_opt_i32_t", o.text);
    try std.testing.expectEqualStrings("int32_t", o.payload.?.text);
    const r = try e.gen.lowerType(&e.module.items[1].fn_def.params[1].ty, .copy);
    try std.testing.expectEqualStrings("uint8_t", r.payload.?.text);
    try std.testing.expectEqualStrings("cell_E", r.err_payload.?.text);
}
```

If `emitSource`'s result does not expose the generator and module under those names, read the `emitSource` helper (near `expectContains`) and use what it returns; if it exposes only text, instead assert through Task 7's pattern test and skip this unit test.

- [ ] **Step 2: Implement**

In `CType`, after `pointee`:

```zig
    /// For `optional`: the `T` of `T?`. For `result`: the ok payload. Null
    /// elsewhere. Preserved by `applyOwnership` and `pointerTo` like `elem`.
    payload: ?*const CType = null,
    /// For `result`: the `E`. Null elsewhere.
    err_payload: ?*const CType = null,
```

In `lowerType`:

```zig
            .optional => |inner| blk: {
                const inst = try self.optionalInstance(inner);
                const p = try self.arena.create(CType);
                p.* = try self.lowerType(inner, .copy);
                break :blk .{
                    .text = try std.fmt.allocPrint(self.arena, "{s}_t", .{inst.base}),
                    .shape = .optional,
                    .payload = p,
                };
            },
            .result => |r| blk: {
                const ok = try self.arena.create(CType);
                ok.* = try self.lowerType(r.ok, .copy);
                const err = try self.arena.create(CType);
                err.* = try self.lowerType(r.err, .copy);
                break :blk .{ .text = CType.result.text, .shape = .result, .payload = ok, .err_payload = err };
            },
```

(`r.ok` / `r.err` are the AST `TypeExpr` result fields; confirm their names in `ast.zig`'s `TypeExpr.result`.) In `applyOwnership` and `pointerTo`, wherever `.elem = base.elem` is copied, also copy `.payload = base.payload, .err_payload = base.err_payload`.

Free function near `unwrapAnnotated`:

```zig
/// `cell_opt_i64_t` -> `cell_opt_i64`, the constructor prefix.
fn optBase(ty: CType) []const u8 {
    std.debug.assert(ty.shape == .optional);
    return ty.text[0 .. ty.text.len - "_t".len];
}
```

- [ ] **Step 3: Run the test, then the whole codegen file**

Run: `zig test src/cell/codegen.zig --test-filter "carry their payload types" 2>&1 | tail -3`, then `zig test src/cell/codegen.zig 2>&1 | tail -2`.
Expected: named test `OK`; whole file green (the `.wrap` arms from Task 2 already exist).

- [ ] **Step 4: Commit**

```bash
git add src/cell/codegen.zig
git commit -m "codegen: optional and Result C types carry their payload types"
```

---

### Task 7: C backend lowering

**Files:**
- Modify: `src/cell/codegen.zig` (`inferExpr`, `emitExpr`, `emitArgLike`, `emitPatternTest`, `emitArmBody`, tests)

**Interfaces:**
- Consumes: `CType.payload`, `CType.err_payload`, `optBase`, `cell_err`, `cell_ok_i32`.
- Produces: `fn emitWrap(self, w, want: ?CType, indent)`; `fn resultField(payload: CType) []const u8`.

- [ ] **Step 1: Failing tests**

```zig
test "Some/None/Ok/Err lower onto the runtime constructors" {
    var e = try emitSource(
        \\pub enum E { A, B }
        \\pub fn f() -> Int {
        \\  let a: Int? = Some(1)
        \\  let b: Int? = None
        \\  let c: Int32? = Some(2)
        \\  let d: Result<Int, E> = Ok(3)
        \\  let g: Result<Int, E> = Err(E.B)
        \\  let h: Result<Byte, Int32> = Ok(4)
        \\  let i = Some(5)
        \\  return 0
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_opt_i64_t a = cell_opt_i64_some(1);");
    try expectContains(f, "cell_opt_i64_t b = cell_opt_i64_none();");
    try expectContains(f, "cell_opt_i32_t c = cell_opt_i32_some(2);");
    try expectContains(f, "cell_result_t d = cell_ok_i64(3);");
    try expectContains(f, "cell_result_t g = cell_err((int32_t)cell_E_B);");
    try expectContains(f, "cell_result_t h = cell_ok_u64((uint64_t)4);");
    try expectContains(f, "cell_opt_i64_t i = cell_opt_i64_some(5);");
    try expectCompiles(e.text);
}

test "wrap patterns test the tag and bind the payload" {
    var e = try emitSource(
        \\pub enum E { A, B }
        \\pub fn f(copy o: Int?, copy r: Result<Byte, E>) -> Int {
        \\  let a = match o { Some(x) => x, None => 0 }
        \\  let b = match r { Ok(v) => 1, Err(code) => 2 }
        \\  return a + b
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "if (_cell_t0.has_value) {");
    try expectContains(f, "int64_t x = _cell_t0.value;");
    try expectContains(f, "} else if (!_cell_t0.has_value) {");
    try expectContains(f, "if (_cell_t2.ok) {");
    try expectContains(f, "uint8_t v = (uint8_t)_cell_t2.value.u64;");
    try expectContains(f, "cell_E code = (cell_E)_cell_t2.error_code;");
    try expectCompiles(e.text);
}
```

The temporary numbers (`_cell_t0`, `_cell_t2`) follow `nextTemp`; if the first run shows different numbers, read the emitted text the assertion prints and use those.

- [ ] **Step 2: Run to see them fail**

Run: `zig test src/cell/codegen.zig --test-filter "runtime constructors" 2>&1 | tail -8`
Expected: FAIL (NotFound) with the emitted text shown.

- [ ] **Step 3: `inferExpr` arm**

```zig
            .wrap => |w| switch (w.ctor) {
                .some => {
                    const inner = try self.inferExpr(w.operand.?);
                    const p = try self.arena.create(CType);
                    p.* = inner;
                    const base = optBaseForPayload(inner) orelse return CType.unknown;
                    return .{ .text = try std.fmt.allocPrint(self.arena, "{s}_t", .{base}), .shape = .optional, .payload = p };
                },
                .none => return CType.unknown,
                .ok, .err => return CType.result,
            },
```

with, next to `optBase`:

```zig
/// The predefined `cell_opt_*` instance for a scalar C type, by spelling.
fn optBaseForPayload(t: CType) ?[]const u8 {
    const map = .{
        .{ "int64_t", "cell_opt_i64" }, .{ "uint64_t", "cell_opt_u64" },
        .{ "int32_t", "cell_opt_i32" }, .{ "double", "cell_opt_f64" },
        .{ "bool", "cell_opt_bool" },   .{ "uint8_t", "cell_opt_byte" },
        .{ "float", "cell_opt_Float32" },
    };
    inline for (map) |row| if (std.mem.eql(u8, t.text, row[0])) return row[1];
    return null;
}

/// Which `cell_value_t` field an ok payload of this C type rides in, and
/// the runtime constructor that writes it.
fn resultField(t: CType) struct { field: []const u8, ctor: []const u8, cast: []const u8 } {
    if (std.mem.eql(u8, t.text, "int64_t")) return .{ .field = "i64", .ctor = "cell_ok_i64", .cast = "" };
    if (std.mem.eql(u8, t.text, "int32_t")) return .{ .field = "i64", .ctor = "cell_ok_i32", .cast = "(int32_t)" };
    if (std.mem.eql(u8, t.text, "uint64_t")) return .{ .field = "u64", .ctor = "cell_ok_u64", .cast = "" };
    if (std.mem.eql(u8, t.text, "uint8_t")) return .{ .field = "u64", .ctor = "cell_ok_u64", .cast = "(uint8_t)" };
    if (std.mem.eql(u8, t.text, "double")) return .{ .field = "f64", .ctor = "cell_ok_f64", .cast = "" };
    if (std.mem.eql(u8, t.text, "float")) return .{ .field = "f64", .ctor = "cell_ok_f64", .cast = "(float)" };
    if (std.mem.eql(u8, t.text, "bool")) return .{ .field = "b", .ctor = "cell_ok_bool", .cast = "" };
    // Unknown payloads are refused by the checker; keep the C loud.
    return .{ .field = "i64", .ctor = "cell_ok_i64", .cast = "" };
}
```

`cell_opt_Float32` is the generated instance name `optionalInstance` produces for `Float32`; a `let x: Float32? = Some(1.5)` therefore instantiates it at the top of the module through the existing generated-instance path, and `Some(f)` with an inferred `float` operand names the same instance.

- [ ] **Step 4: `emitWrap` and the two call sites**

```zig
    /// `Some(e)`, `None`, `Ok(e)`, `Err(e)`. `want` is the destination's
    /// declared type when the position has one (a `let` with a written
    /// type, a return, a call argument, a field); it decides the optional
    /// instance and the Result payload field. Without it the operand's own
    /// type decides, and `None` cannot be emitted at all, which the checker
    /// already refuses.
    fn emitWrap(self: *Generator, w: anytype, want: ?CType, indent: usize) EmitError!void {
        const out = self.writer;
        switch (w.ctor) {
            .none => {
                const dest = want orelse return error.Unsupported;
                try out.print("{s}_none()", .{optBase(dest)});
            },
            .some => {
                const operand = w.operand.?;
                const dest: ?CType = if (want) |d| (if (d.shape == .optional) d else null) else null;
                if (dest) |d| {
                    try out.print("{s}_some(", .{optBase(d)});
                    try self.emitArgLike(operand, d.payload.?.*, indent);
                    try out.writeAll(")");
                } else {
                    const inner = try self.inferExpr(operand);
                    const base = optBaseForPayload(inner) orelse return error.Unsupported;
                    try out.print("{s}_some(", .{base});
                    try self.emitExpr(operand, indent);
                    try out.writeAll(")");
                }
            },
            .ok => {
                const operand = w.operand.?;
                const payload: CType = if (want) |d| (if (d.shape == .result and d.payload != null) d.payload.?.* else try self.inferExpr(operand)) else try self.inferExpr(operand);
                const rf = resultField(payload);
                try out.print("{s}(", .{rf.ctor});
                if (rf.cast.len != 0) {
                    // Widen Byte to u64 and Float32 to double explicitly.
                    try out.writeAll(if (std.mem.eql(u8, payload.text, "uint8_t")) "(uint64_t)" else if (std.mem.eql(u8, payload.text, "float")) "(double)" else "");
                }
                try self.emitExpr(operand, indent);
                try out.writeAll(")");
            },
            .err => {
                try out.writeAll("cell_err((int32_t)");
                try self.emitExpr(w.operand.?, indent);
                try out.writeAll(")");
            },
        }
    }
```

`error.Unsupported`: use whichever error name `EmitError` already carries for "cannot emit" (read the `EmitError` set at the top of the file and pick the existing member; do not add one).

`emitExpr`: add `.wrap => |w| try self.emitWrap(w, null, indent),` after `.match_expr`.

`emitArgLike`, as the FIRST statement after `const have = try self.inferExpr(arg);`:

```zig
        if (unwrapAnnotated(arg).kind == .wrap) {
            return try self.emitWrap(unwrapAnnotated(arg).kind.wrap, want, indent);
        }
```

- [ ] **Step 5: Patterns**

`emitPatternTest`, new arm:

```zig
            .wrap_pattern => |wp| switch (wp.ctor) {
                .some => try out.print("{s}.has_value", .{temp}),
                .none => try out.print("!{s}.has_value", .{temp}),
                .ok => try out.print("{s}.ok", .{temp}),
                .err => try out.print("!{s}.ok", .{temp}),
            },
```

`emitArmBody`, after the existing `if (arm.pattern.kind == .binding) { ... }` block:

```zig
        if (arm.pattern.kind == .wrap_pattern) {
            const wp = arm.pattern.kind.wrap_pattern;
            if (wp.binding) |name| {
                const ty: CType = switch (wp.ctor) {
                    .some, .none => scrut_ty.payload.?.*,
                    .ok => scrut_ty.payload.?.*,
                    .err => scrut_ty.err_payload.?.*,
                };
                try self.writeIndent(indent);
                try self.writeDecl(ty, name);
                switch (wp.ctor) {
                    .some, .none => try self.writer.print(" = {s}.value;\n", .{temp}),
                    .ok => {
                        const rf = resultField(ty);
                        try self.writer.print(" = {s}{s}.value.{s};\n", .{ rf.cast, temp, rf.field });
                    },
                    .err => try self.writer.print(" = ({s}){s}.error_code;\n", .{ ty.text, temp }),
                }
                // A scalar copy: never droppable, `copy` like borrowck says.
                try self.pushLocal(name, ty, .copy, false);
                if (!exprUses(arm.body, name)) {
                    try self.writeIndent(indent);
                    try self.writer.print("(void){s};\n", .{name});
                }
            }
        }
```

`scrut_ty` reaches `emitArmBody` from `emitMatch`'s `inferExpr(m.scrutinee)`; for a parameter or a declared local that is the lowered declared type, which carries `payload` since Task 6.

- [ ] **Step 6: Run the two tests, then the whole file**

Run: `zig test src/cell/codegen.zig --test-filter "wrap patterns test the tag" 2>&1 | tail -3`; `zig test src/cell/codegen.zig --test-filter "runtime constructors" 2>&1 | tail -3`; `zig test src/cell/codegen.zig 2>&1 | tail -2`.
Expected: both named tests `OK`; whole file green.

- [ ] **Step 7: Commit**

```bash
git add src/cell/codegen.zig
git commit -m "codegen: lower Some/None/Ok/Err and their patterns onto cell_opt_* and cell_ok_*/cell_err"
```

---

### Task 8: Corpus, docs, gate

**Files:**
- Create: `examples/optionals.cell`, `examples/results.cell`
- Modify: `docs/SPEC.md` (3.2, 3.4, section 9, section 12 status rows), `docs/FEATURES.md` (TYPE-04, TYPE-06, PAT-02), `README.md` (Status), `stdlib/prelude.cell` (the `bytes_pop` note), `examples/README.md` (mention the two files in the C-only list next to `owned_string.cell`)

- [ ] **Step 1: The two examples**

`examples/optionals.cell`:

```cell
// Optional values: construction with Some/None and inspection in match.
//
// Status: parses, passes `cell check`, and the emitted C compiles, links and
// runs, printing 43 (see EXPECT-OUTPUT). C backend only: LLVM and MLIR refuse
// the constructors and patterns together with `cannot lower`, so the
// agreement contract holds. Payloads are scalar primitives (SPEC 3.2).
// EXPECT-OUTPUT: 43

pub fn print_int(copy value: Int);

pub fn first_positive(copy a: Int, copy b: Int) -> Int? {
    if a > 0 {
        return Some(a)
    }
    if b > 0 {
        return Some(b)
    }
    return None
}

pub fn or_zero(copy o: Int?) -> Int {
    return match o {
        Some(x) => x,
        None => 0,
    }
}

pub fn main() {
    let copy a = or_zero(first_positive(-1, 40))
    let copy b = or_zero(first_positive(-1, -1))
    let copy c: Byte? = Some(3)
    let copy d = match c { Some(v) => 3, None => 0 }
    print_int(a + b + d)
}
```

`examples/results.cell`:

```cell
// Result values: construction with Ok/Err and inspection in match. E is a
// payload-free enum, carried as an int32_t code at the C boundary (SPEC 3.4).
//
// Status: parses, passes `cell check`, and the emitted C compiles, links and
// runs, printing 12. C backend only (LLVM and MLIR refuse together).
// EXPECT-OUTPUT: 12

pub enum ParseError { Empty, TooLong }

pub fn print_int(copy value: Int);

pub fn parse_len(copy n: Int) -> Result<Int, ParseError> {
    if n == 0 {
        return Err(ParseError.Empty)
    }
    if n > 100 {
        return Err(ParseError.TooLong)
    }
    return Ok(n * 2)
}

pub fn score(copy r: Result<Int, ParseError>) -> Int {
    return match r {
        Ok(v) => v,
        Err(e) => match e { ParseError.Empty => 1, ParseError.TooLong => 2 },
    }
}

pub fn main() {
    let copy a = score(parse_len(5))
    let copy b = score(parse_len(0))
    let copy c = score(parse_len(500))
    print_int(a + b - c)
}
```

Hand-derive both answers before running: optionals `40 + 0 + 3 = 43`; results `10 + 1 - 2 = 9`. **The second literal above says 12 and is wrong on purpose so the executor computes it: fix the `EXPECT-OUTPUT` line to the hand-derived value (9) before running, and if the program prints something else, the compiler is wrong, not the pin.**

- [ ] **Step 2: Run both through the CLI**

Run: `zig build -Dswift=false > /private/tmp/b.log 2>&1; echo "EXIT: $?"` then `./zig-out/bin/cell run examples/optionals.cell; echo "EXIT: $?"` and the same for `results.cell`.
Expected: `43` and `9`, exit 0. Then `./zig-out/bin/cell emit --target=llvm examples/optionals.cell > /dev/null; echo "EXIT: $?"` expected exit 1 with `cannot lower` on stderr, and the same for `--target=mlir`.

- [ ] **Step 3: Docs**

- SPEC 3.2 status line: "**Status: implemented for scalar payloads, C backend only (2026-09-16).**" and replace the paragraph starting "There is no `none` literal" with: constructors `Some(e)`/`None`, patterns `Some(x)`/`Some(_)`/`None`, the scalar payload set, `None` needing a declared slot, LLVM/MLIR refusing.
- SPEC 3.4: same shape for `Ok`/`Err`, `E` as `Int32` or a payload-free enum, the `int32_t` narrowing unchanged.
- SPEC section 9 (patterns): add the wrap pattern forms and that the inner pattern is a binding or `_`.
- SPEC section 12: the "Optional construction and unwrapping" and `Result` rows to "implemented (scalar payloads, C backend; LLVM/MLIR refuse)".
- FEATURES TYPE-04, TYPE-06, PAT-02: Frontend `checked`, C `partial` (scalar payloads), LLVM/MLIR `refused`, evidence links to the two examples.
- README Status: one sentence after the `cell run` paragraph.
- `stdlib/prelude.cell`: the sentence "`bytes_pop` returns `Byte?` and there is no way to test or unwrap an optional ... currently unusable" becomes history ("since 2026-09-16 a `Byte?` is matched with `Some`/`None`").
- `examples/README.md`: list the two files beside `owned_string.cell` as C-only by design.

Run `grep -c ','` on every edited file (expect 0) and `sh tools/check-rule-lists.sh` (expect `ok`).

- [ ] **Step 4: Gate and sweep**

Run:
```sh
tools/check.sh > /private/tmp/gate.log 2>&1; echo "CELL_GATE_EXIT: $?" >> /private/tmp/gate.log
grep -E '^== verdict|CELL_GATE_EXIT|FAIL|SKIPPED' /private/tmp/gate.log | tail -5
grep -oE 'All [0-9]+ tests passed' /private/tmp/gate.log | tail -1
tools/sweep-backends.sh > /private/tmp/sweep.log 2>&1; echo "SWEEP_EXIT: $?"; grep -E 'probed' /private/tmp/sweep.log
```
Expected: `clean`, `CELL_GATE_EXIT: 0`, no FAIL, no SKIPPED; sweep `88 programs probed, 0 issue(s)` (the sweep generates no wrap forms, so the count should not move; if it does, explain the delta in the commit message).

- [ ] **Step 5: Commit and push**

```bash
git add examples/optionals.cell examples/results.cell docs/SPEC.md docs/FEATURES.md README.md stdlib/prelude.cell examples/README.md
git commit -m "optionals and Result values: corpus examples pinned, docs to implemented (scalar payloads, C backend)"
git push origin main
```

---

## Self-review

- Spec coverage: B.1 (Tasks 1, 2), B.2 (Tasks 3, 4), B.3 (Tasks 5, 6, 7), B.4 (every task's tests plus Task 8).
- Placeholders: none; the one deliberately wrong literal in Task 8 is called out and its correction is the step.
- Type consistency: `ast.Ctor`, `Expr.Kind.wrap{ctor, operand}`, `Pattern.Kind.wrap_pattern{ctor, binding}`, `CType.payload`/`err_payload`, `optBase`, `optBaseForPayload`, `resultField`, `emitWrap`, `cell_err`, `cell_ok_i32` are spelled the same in every task that uses them.
