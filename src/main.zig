const std = @import("std");
const cell = @import("cell");
const Io = std.Io;

// C runtime ABI (Zig master: no @cImport, so declare externs)
const CellString = extern struct {
    ptr: ?[*]u8,
    len: usize,
    cap: usize,
};
extern fn cell_rt_version() CellString;
extern fn cell_string_free(s: *CellString) void;
extern fn cell_cxx_probe() c_int;
extern fn cell_swift_probe() c_int;

/// The C runtime, embedded so `build` and `run` work from any directory
/// and never depend on the caller's checkout. build.zig binds both names
/// with `addAnonymousImport` on the exe and test modules; the gate's own
/// execution stage compiles the same two files from `runtime/` directly.
const embedded_rt_h = @embedFile("cell_rt_h");
const embedded_rt_c = @embedFile("cell_rt_c");

const Usage =
    \\cell - Cell language toolchain (Zig host)
    \\
    \\USAGE:
    \\  cell <command> [args]
    \\
    \\COMMANDS:
    \\  check <file.cell>     Parse + typecheck + borrow-check
    \\  dump  <file.cell>     Parse and print AST
    \\  emit  <file.cell>     Emit code (see --target)
    \\  build <file.cell> [host.c ...]  Compile to an executable with cc (C target only)
    \\  run   <file.cell> [host.c ...]  Build into a temp dir, execute, forward the exit code
    \\  test  [dir]           Run every .cell program in dir (default tests/) like `run`; see below
    \\  version               Print version
    \\  help                  Show this help
    \\
    \\OPTIONS:
    \\  --target=c            Emit C against runtime/cell_rt.h (default)
    \\  --target=llvm         Emit textual LLVM IR
    \\  --target=mlir         Emit textual MLIR (func/arith/memref/scf)
    \\  -o <path>             Output path for build (default: the source stem)
    \\
    \\The llvm and mlir backends are scalar-first. A construct they cannot
    \\carry yet is reported as a `cannot lower` error at its span, not
    \\emitted as something that looks plausible.
    \\
    \\build and run stage the emitted C beside an embedded copy of the runtime
    \\(runtime/cell_rt.h and cell_rt.c) under $TMPDIR, then invoke $CC
    \\(default: cc) on them, the same recipe tools/check.sh executes. Extra
    \\positionals ending in .c are hand-written C hosts for the program's
    \\bodyless declarations (examples/*_host.c); they are handed to cc as given,
    \\between the emitted C and the runtime, and are refused by every other
    \\command, so a .c file is never loaded as Cell source.
    \\
    \\test runs each program in the directory through the run recipe, in name
    \\order, pairing <stem>_host.c beside it as its host. A program passes on
    \\exit 0, and when its source carries `// EXPECT-OUTPUT: <text>`, its
    \\stdout must equal <text>. Exit 0 all passed, 1 any failed, 2 when the
    \\directory is missing or holds no program.
    \\
;

/// Every command the dispatcher accepts, and the single source of truth the
/// usage text is checked against.
///
/// This exists because the test at the bottom of this file used to be
/// `try std.testing.expect(true)`, which is why AGENTS.md warns that a green
/// `zig build test` is weak evidence here. A CLI's testable contract, short
/// of spawning the binary, is that its help text and its dispatcher agree:
/// a command documented but not handled, or handled but not documented, is
/// a real defect that ships silently. Naming the commands once, dispatching
/// through a switch on this enum, and checking the usage text against the
/// enum's own reflected field names makes that drift a build failure instead.
///
/// Read those names with `@typeInfo(Command).@"enum".field_names`, NOT with
/// `std.meta.fields`, which this comment named until 2026-09-07 and which is
/// now a `@compileError` on Zig master. `Type.Enum` there carries parallel
/// `field_names` and `field_values` slices rather than a `fields` array of
/// structs.
const Command = enum { check, dump, emit, build, run, @"test", version, help };

/// Aliases are handled here rather than in the dispatcher so there is one
/// place where a spelling becomes a Command, and so the test can assert the
/// aliases actually map (a `-V` that silently stopped meaning `version`
/// would otherwise reach the "unknown command" branch with no test noticing).
fn parseCommand(s: []const u8) ?Command {
    if (std.mem.eql(u8, s, "-h") or std.mem.eql(u8, s, "--help")) return .help;
    if (std.mem.eql(u8, s, "-V")) return .version;
    return std.meta.stringToEnum(Command, s);
}

/// The `--target=` values, likewise named once. Returns null for anything
/// else, so the caller owns the diagnostic and the exit code.
fn parseTarget(name: []const u8) ?cell.Target {
    if (std.mem.eql(u8, name, "c")) return .c;
    if (std.mem.eql(u8, name, "llvm")) return .llvm;
    if (std.mem.eql(u8, name, "mlir")) return .mlir;
    return null;
}

/// Everything a file command needs from argv, resolved before anything
/// touches the disk.
const Invocation = struct {
    path: []const u8,
    target: cell.Target = .c,
    out: ?[]const u8 = null,
    /// Host C sources, bounded so the struct can be returned by value: a
    /// slice into its own array would dangle. Read through `hosts()`.
    host_buf: [max_hosts][]const u8 = undefined,
    host_count: usize = 0,

    pub const max_hosts = 8;

    pub fn hosts(self: *const Invocation) []const []const u8 {
        return self.host_buf[0..self.host_count];
    }
};

/// The outcome of `parseArgs`. Each refusal carries the offending token so
/// the caller can name it; the parser itself prints nothing and exits
/// nowhere, which is what makes it testable.
const ParsedArgs = union(enum) {
    ok: Invocation,
    missing_file,
    missing_out_value,
    extra_positional: []const u8,
    unknown_target: []const u8,
    unknown_option: []const u8,
    too_many_hosts,
};

/// Parse the arguments after the command. The path, `--target=`, `-o` and
/// any `.c` host sources may appear in any order. A second non-host
/// positional is refused rather than dropped: until 2026-09-16 the loop kept
/// the first path and said nothing about the rest, which for `build` would
/// have compiled a.cell in silence when handed `a.cell b.cell`. A `.c`
/// positional is a host for build/run and never a Cell source, even though
/// `load`'s unknown-extension fallback would once have read it as one.
fn parseArgs(args: []const []const u8) ParsedArgs {
    var inv: Invocation = .{ .path = "" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.startsWith(u8, a, "--target=")) {
            const name = a["--target=".len..];
            inv.target = parseTarget(name) orelse return .{ .unknown_target = name };
        } else if (std.mem.eql(u8, a, "-o")) {
            if (i + 1 >= args.len) return .missing_out_value;
            i += 1;
            inv.out = args[i];
        } else if (a.len > 1 and a[0] == '-') {
            return .{ .unknown_option = a };
        } else if (std.mem.eql(u8, std.fs.path.extension(a), ".c")) {
            if (inv.host_count == Invocation.max_hosts) return .too_many_hosts;
            inv.host_buf[inv.host_count] = a;
            inv.host_count += 1;
        } else if (inv.path.len == 0) {
            inv.path = a;
        } else {
            return .{ .extra_positional = a };
        }
    }
    if (inv.path.len == 0) return .missing_file;
    return .{ .ok = inv };
}

/// `build`'s output path when `-o` is absent: the source with the extension
/// `load` accepts removed. A path with no such extension gets `.out`
/// appended, because returning it unchanged would hand cc the source file
/// as its own output and overwrite it.
/// The corpus convention tools/check.sh stage 8 reads: the text after the
/// first line that STARTS with `// EXPECT-OUTPUT:`, surrounding spaces
/// trimmed. Null when no such line exists.
fn expectOutputOf(source: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const marker = "// EXPECT-OUTPUT:";
        if (std.mem.startsWith(u8, line, marker)) {
            return std.mem.trim(u8, line[marker.len..], " \t\r");
        }
    }
    return null;
}

const Outcome = union(enum) {
    passed,
    passed_matched,
    failed_exit: u8,
    failed_signal: struct { name: []const u8, signo: u8 },
    failed_output: struct { want: []const u8, got: []const u8 },
    failed_compile,
};

fn reportLine(buf: []u8, name: []const u8, outcome: Outcome) []const u8 {
    return switch (outcome) {
        .passed => std.fmt.bufPrint(buf, "ok    {s}", .{name}) catch buf[0..0],
        .passed_matched => std.fmt.bufPrint(buf, "ok    {s} (output matched)", .{name}) catch buf[0..0],
        .failed_exit => |code| std.fmt.bufPrint(buf, "FAIL  {s} (exit {d})", .{ name, code }) catch buf[0..0],
        .failed_signal => |sig| std.fmt.bufPrint(buf, "FAIL  {s} (exit {d}: program terminated by signal {s})", .{ name, @as(u16, 128) + sig.signo, sig.name }) catch buf[0..0],
        .failed_output => |o| std.fmt.bufPrint(buf, "FAIL  {s} (expected output '{s}', got '{s}')", .{ name, o.want, o.got }) catch buf[0..0],
        .failed_compile => std.fmt.bufPrint(buf, "FAIL  {s} (did not compile)", .{name}) catch buf[0..0],
    };
}

fn defaultOutput(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const ext = std.fs.path.extension(path);
    const known = [_][]const u8{ ".cell", ".cel", ".body", ".bod" };
    for (known) |k| {
        if (std.mem.eql(u8, ext, k)) return allocator.dupe(u8, path[0 .. path.len - ext.len]);
    }
    return std.fmt.allocPrint(allocator, "{s}.out", .{path});
}

/// The cc command line, in the shape tools/check.sh stage 6 uses
/// (`cc -I runtime main.c [host.c ...] runtime/cell_rt.c -o out`), with
/// `runtime/` replaced by the staging directory the embedded runtime was
/// written to. Hosts pass through as given, between the emitted C and the
/// runtime, which is run_c_host's order; cc inherits the cwd, so a path
/// relative to the checkout resolves and nothing is staged for them. No
/// `-Werror`: the gate's corpus stage is where warnings are a failure, and
/// a user program that trips one should still run.
fn ccArgv(
    allocator: std.mem.Allocator,
    cc: []const u8,
    stage_dir: []const u8,
    main_c: []const u8,
    hosts: []const []const u8,
    out: []const u8,
) ![]const []const u8 {
    const rt_c = try std.fs.path.join(allocator, &.{ stage_dir, "cell_rt.c" });
    const argv = try allocator.alloc([]const u8, 7 + hosts.len);
    argv[0..4].* = .{ cc, "-I", stage_dir, main_c };
    @memcpy(argv[4 .. 4 + hosts.len], hosts);
    argv[4 + hosts.len ..][0..3].* = .{ rt_c, "-o", out };
    return argv;
}

/// Only build and run invoke cc, so only they can do anything with a host
/// source. Null means go ahead.
fn hostRefusal(command: Command, host_count: usize) ?[]const u8 {
    if (host_count == 0) return null;
    return switch (command) {
        .build, .run => null,
        else => "host .c sources apply to build and run only",
    };
}

/// Only the C backend produces something cc can compile. Null means go
/// ahead; otherwise the message redirects to the command that does print
/// that target's text.
fn buildTargetRefusal(target: cell.Target) ?[]const u8 {
    return switch (target) {
        .c => null,
        .llvm => "build compiles the C backend's output only; `cell emit --target=llvm` prints the textual IR",
        .mlir => "build compiles the C backend's output only; `cell emit --target=mlir` prints the textual MLIR",
    };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    if (args.len < 2) {
        try printUsage(io);
        std.process.exit(1);
    }

    const cmd = args[1];
    const command = parseCommand(cmd);
    if (command == .help) {
        try printUsage(io);
        return;
    }
    if (command == .version) {
        std.debug.print("cell {d}.{d}.{d} (zig host + c/cxx/swift bridges)\n", .{
            cell.Version.major,
            cell.Version.minor,
            cell.Version.patch,
        });
        var rt_ver = cell_rt_version();
        if (rt_ver.ptr) |p| {
            std.debug.print("runtime: {s}\n", .{p[0..rt_ver.len]});
        }
        cell_string_free(&rt_ver);
        std.debug.print("cxx probe: {d}\n", .{cell_cxx_probe()});
        std.debug.print("swift probe: {d}\n", .{cell_swift_probe()});
        return;
    }

    const inv: Invocation = switch (parseArgs(args[2..])) {
        .ok => |v| v,
        .missing_file => if (command == .@"test") Invocation{ .path = "tests" } else blk: {
            std.debug.print("error: missing file argument\n\n", .{});
            try printUsage(io);
            std.process.exit(1);
            break :blk Invocation{ .path = "" };
        },
        .missing_out_value => {
            std.debug.print("error: -o needs a path\n", .{});
            std.process.exit(1);
        },
        .extra_positional => |a| {
            std.debug.print("error: unexpected argument '{s}' (one source file per invocation)\n", .{a});
            std.process.exit(1);
        },
        .unknown_target => |name| {
            std.debug.print("error: unknown target '{s}' (want c, llvm or mlir)\n", .{name});
            std.process.exit(1);
        },
        .unknown_option => |a| {
            std.debug.print("error: unknown option '{s}'\n\n", .{a});
            try printUsage(io);
            std.process.exit(1);
        },
        .too_many_hosts => {
            std.debug.print("error: at most {d} host .c sources per invocation\n", .{Invocation.max_hosts});
            std.process.exit(1);
        },
    };
    if (inv.out != null and command != .build) {
        std.debug.print("error: -o applies to build only\n", .{});
        std.process.exit(1);
    }
    if (command == .@"test" and inv.target != .c) {
        std.debug.print("error: test compiles the C target only; `cell emit --target={s}` prints the textual IR\n", .{@tagName(inv.target)});
        std.process.exit(1);
    }
    if (command) |c| {
        if (hostRefusal(c, inv.host_count)) |why| {
            std.debug.print("error: {s}\n", .{why});
            std.process.exit(1);
        }
    }
    const path = inv.path;
    const target = inv.target;
    const cwd = Io.Dir.cwd();

    if (command == .@"test") {
        const code = try testDir(init, cwd, inv.path);
        std.process.exit(code);
    }

    if (command == .build or command == .run) {
        // A function rather than inline, so its defers (the staging
        // directory's removal) run before the process exits with the
        // program's own code.
        const code = try buildOrRun(init, cwd, command.?, inv);
        std.process.exit(code);
    }

    if (command == .check) {
        var buf: [4096]u8 = undefined;
        var fw: Io.File.Writer = .init(.stderr(), io, &buf);
        var module = loadAndReport(arena, io, cwd, path, &fw) catch |err| {
            if (err == error.TypeError) std.process.exit(1);
            return err;
        };
        defer module.deinit(arena);
        std.debug.print("ok: {s} ({d} items)\n", .{ path, module.items.len });
        return;
    }

    if (command == .dump) {
        var buf: [4096]u8 = undefined;
        var fw: Io.File.Writer = .init(.stderr(), io, &buf);
        var loaded = cell.load(arena, io, cwd, path, &fw.interface) catch |err| {
            try fw.interface.flush();
            if (err == error.MissingModule or err == error.AmbiguousModule or err == error.PairingMismatch or err == error.ParseFailed) std.process.exit(1);
            return err;
        };
        try loaded.module.dump(&fw.interface);
        try fw.interface.flush();
        return;
    }

    if (command == .emit) {
        var err_buf: [4096]u8 = undefined;
        var err_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);

        // Loaded rather than loadAndCheck, so the source buffer is still in
        // hand and a backend's `cannot lower` diagnostic renders with the
        // offending line and a caret rather than a bare location.
        var loaded = cell.load(arena, io, cwd, path, &err_fw.interface) catch |err| {
            try err_fw.interface.flush();
            if (err == error.MissingModule or err == error.AmbiguousModule or
                err == error.PairingMismatch or err == error.ParseFailed)
                std.process.exit(1);
            return err;
        };
        cell.check(arena, &loaded.module, loaded.source, &err_fw.interface) catch |err| {
            try err_fw.interface.flush();
            if (err == error.TypeError) std.process.exit(1);
            return err;
        };
        try err_fw.interface.flush();

        var buf: [8192]u8 = undefined;
        var fw: Io.File.Writer = .init(.stdout(), io, &buf);
        cell.emitFor(arena, &loaded.module, loaded.source, &fw.interface, target, &err_fw.interface) catch |err| {
            try fw.interface.flush();
            try err_fw.interface.flush();
            if (err == error.TypeError) std.process.exit(1);
            return err;
        };
        try fw.interface.flush();
        return;
    }

    // Every Command is handled and returned above. Listing them here is not
    // decoration: adding a variant to Command without giving it a branch
    // makes THIS switch non-exhaustive and fails the build, which is the
    // only mechanism that forces the author back to this function. Reaching
    // it at runtime would mean a branch above stopped returning.
    if (command) |c| switch (c) {
        .check, .dump, .emit, .build, .run, .@"test", .version, .help => unreachable,
    };

    std.debug.print("error: unknown command '{s}'\n\n", .{cmd});
    try printUsage(io);
    std.process.exit(1);
}

/// `build` and `run`. Load, check and emit exactly as `emit` does (so stem
/// pairing, every diagnostic and the `cannot lower` path are inherited, not
/// re-implemented), write the C beside the embedded runtime in a fresh
/// directory under $TMPDIR, and hand the three files to $CC. `build` leaves
/// the executable at `-o` or the source stem; `run` builds into the staging
/// directory, executes the result with inherited stdio, and returns its
/// exit code. Returns the process exit code instead of exiting so the
/// staging directory is always removed on the way out.
fn buildOrRun(init: std.process.Init, cwd: Io.Dir, command: Command, inv: Invocation) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var err_buf: [4096]u8 = undefined;
    var err_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err_w = &err_fw.interface;

    if (command == .run) {
        if (buildTargetRefusal(inv.target)) |why| {
            try err_w.print("error: {s}\n", .{why});
            try err_w.flush();
            return 1;
        }
        const outcome = try runProgram(init, cwd, inv.path, inv.hosts(), false, err_w);
        return switch (outcome) {
            .compile_failed => 1,
            .ran => |r| exitCodeOf(r.term, err_w),
        };
    }

    if (buildTargetRefusal(inv.target)) |why| {
        try err_w.print("error: {s}\n", .{why});
        try err_w.flush();
        return 1;
    }

    var loaded = cell.load(arena, io, cwd, inv.path, err_w) catch |err| {
        try err_w.flush();
        if (err == error.MissingModule or err == error.AmbiguousModule or
            err == error.PairingMismatch or err == error.ParseFailed)
            return 1;
        return err;
    };
    cell.check(arena, &loaded.module, loaded.source, err_w) catch |err| {
        try err_w.flush();
        if (err == error.TypeError) return 1;
        return err;
    };
    try err_w.flush();

    // An allocating writer, not a fixed buffer: a program's C is not bounded.
    var c_text: Io.Writer.Allocating = .init(arena);
    cell.emitFor(arena, &loaded.module, loaded.source, &c_text.writer, inv.target, err_w) catch |err| {
        try err_w.flush();
        if (err == error.TypeError) return 1;
        return err;
    };
    try err_w.flush();

    const tmp_root = std.mem.trimEnd(u8, init.environ_map.get("TMPDIR") orelse "/tmp", "/");
    const nanos = Io.Clock.real.now(io).nanoseconds;
    const stage = try std.fmt.allocPrint(arena, "{s}/cell-build-{d}", .{ tmp_root, nanos });
    cwd.createDirPath(io, stage) catch |err| {
        try err_w.print("error: cannot create staging directory '{s}': {s}\n", .{ stage, @errorName(err) });
        try err_w.flush();
        return 1;
    };
    defer cwd.deleteTree(io, stage) catch {};

    const main_c = try std.fs.path.join(arena, &.{ stage, "main.c" });
    try cwd.writeFile(io, .{ .sub_path = main_c, .data = c_text.written() });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ stage, "cell_rt.h" }), .data = embedded_rt_h });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ stage, "cell_rt.c" }), .data = embedded_rt_c });

    const out: []const u8 = switch (command) {
        .build => inv.out orelse try defaultOutput(arena, inv.path),
        .run => try std.fs.path.join(arena, &.{ stage, "a.out" }),
        else => unreachable,
    };
    const cc = init.environ_map.get("CC") orelse "cc";
    const argv = try ccArgv(arena, cc, stage, main_c, inv.hosts(), out);
    const result = std.process.run(init.gpa, io, .{ .argv = argv }) catch |err| {
        try err_w.print("error: cannot run '{s}': {s} (set CC to a working C compiler)\n", .{ cc, @errorName(err) });
        try err_w.flush();
        return 1;
    };
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (!result.term.success()) {
        // cc's own diagnostics verbatim, then the pointer to the text it
        // rejected. Nothing is left at `out`: cc does not write an output
        // it failed to produce.
        try err_w.writeAll(result.stderr);
        try err_w.print("error: {s} rejected the emitted C for '{s}' (`cell emit {s}` prints it)\n", .{ cc, inv.path, inv.path });
        try err_w.flush();
        return 1;
    }
    return 0;
}

fn exitCodeOf(term: std.process.Child.Term, err_w: *Io.Writer) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| blk: {
            err_w.print("error: program terminated by signal {s}\n", .{@tagName(sig)}) catch {};
            err_w.flush() catch {};
            break :blk @truncate(128 + @as(u32, @backingInt(sig)));
        },
        else => 1,
    };
}

const RunOutcome = union(enum) {
    compile_failed,
    ran: struct { term: std.process.Child.Term, stdout: []const u8 },
};

/// Load, check, emit and stage `path` exactly as `build`/`run` do, compile
/// with $CC, then execute the result. With `capture` the child's stdout is
/// collected (for `test`); without it stdio is inherited (for `run`).
/// The staging directory is removed on every path out.
fn runProgram(
    init: std.process.Init,
    cwd: Io.Dir,
    path: []const u8,
    hosts: []const []const u8,
    capture: bool,
    err_w: *Io.Writer,
) !RunOutcome {
    const arena = init.arena.allocator();
    const io = init.io;

    if (buildTargetRefusal(.c)) |why| {
        try err_w.print("error: {s}\n", .{why});
        try err_w.flush();
        return .compile_failed;
    }

    var loaded = cell.load(arena, io, cwd, path, err_w) catch |err| {
        try err_w.flush();
        if (err == error.MissingModule or err == error.AmbiguousModule or
            err == error.PairingMismatch or err == error.ParseFailed)
            return .compile_failed;
        return err;
    };
    cell.check(arena, &loaded.module, loaded.source, err_w) catch |err| {
        try err_w.flush();
        if (err == error.TypeError) return .compile_failed;
        return err;
    };
    try err_w.flush();

    var c_text: Io.Writer.Allocating = .init(arena);
    cell.emitFor(arena, &loaded.module, loaded.source, &c_text.writer, .c, err_w) catch |err| {
        try err_w.flush();
        if (err == error.TypeError) return .compile_failed;
        return err;
    };
    try err_w.flush();

    const tmp_root = std.mem.trimEnd(u8, init.environ_map.get("TMPDIR") orelse "/tmp", "/");
    const nanos = Io.Clock.real.now(io).nanoseconds;
    const stage = try std.fmt.allocPrint(arena, "{s}/cell-build-{d}", .{ tmp_root, nanos });
    cwd.createDirPath(io, stage) catch |err| {
        try err_w.print("error: cannot create staging directory '{s}': {s}\n", .{ stage, @errorName(err) });
        try err_w.flush();
        return .compile_failed;
    };
    defer cwd.deleteTree(io, stage) catch {};

    const main_c = try std.fs.path.join(arena, &.{ stage, "main.c" });
    try cwd.writeFile(io, .{ .sub_path = main_c, .data = c_text.written() });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ stage, "cell_rt.h" }), .data = embedded_rt_h });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ stage, "cell_rt.c" }), .data = embedded_rt_c });

    const out = try std.fs.path.join(arena, &.{ stage, "a.out" });
    const cc = init.environ_map.get("CC") orelse "cc";
    const argv = try ccArgv(arena, cc, stage, main_c, hosts, out);
    const compiled = std.process.run(init.gpa, io, .{ .argv = argv }) catch |err| {
        try err_w.print("error: cannot run '{s}': {s} (set CC to a working C compiler)\n", .{ cc, @errorName(err) });
        try err_w.flush();
        return .compile_failed;
    };
    defer init.gpa.free(compiled.stdout);
    defer init.gpa.free(compiled.stderr);
    if (!compiled.term.success()) {
        try err_w.writeAll(compiled.stderr);
        try err_w.print("error: {s} rejected the emitted C for '{s}' (`cell emit {s}` prints it)\n", .{ cc, path, path });
        try err_w.flush();
        return .compile_failed;
    }

    if (!capture) {
        var child = std.process.spawn(io, .{ .argv = &.{out} }) catch |err| {
            try err_w.print("error: cannot execute '{s}': {s}\n", .{ out, @errorName(err) });
            try err_w.flush();
            return .compile_failed;
        };
        const term = try child.wait(io);
        return .{ .ran = .{ .term = term, .stdout = "" } };
    }
    const result = std.process.run(init.gpa, io, .{ .argv = &.{out} }) catch |err| {
        try err_w.print("error: cannot execute '{s}': {s}\n", .{ out, @errorName(err) });
        try err_w.flush();
        return .compile_failed;
    };
    init.gpa.free(result.stderr);
    const stdout = try arena.dupe(u8, result.stdout);
    init.gpa.free(result.stdout);
    return .{ .ran = .{ .term = result.term, .stdout = stdout } };
}

/// `cell test [dir]`. Every `.cell`/`.cel` directly inside `dir`, sorted by
/// name, run through `runProgram` with `<stem>_host.c` as its host when
/// that file exists beside it. Returns the process exit code: 0 when every
/// program passed, 1 when any failed, 2 when `dir` cannot be opened or
/// holds no program (an empty suite is never green).
fn testDir(init: std.process.Init, cwd: Io.Dir, dir: []const u8) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var err_buf: [4096]u8 = undefined;
    var err_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err_w = &err_fw.interface;
    var out_buf: [4096]u8 = undefined;
    var out_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out_w = &out_fw.interface;
    defer out_w.flush() catch {};
    defer err_w.flush() catch {};

    var d = cwd.openDir(io, dir, .{ .iterate = true }) catch |err| {
        try err_w.print("error: cannot open test directory '{s}': {s}\n", .{ dir, @errorName(err) });
        return 2;
    };
    defer d.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.name);
        if (!std.mem.eql(u8, ext, ".cell") and !std.mem.eql(u8, ext, ".cel")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    if (names.items.len == 0) {
        try err_w.print("error: no .cell program in '{s}'\n", .{dir});
        return 2;
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var passed: usize = 0;
    var failed: usize = 0;
    for (names.items) |name| {
        const path = try std.fs.path.join(arena, &.{ dir, name });
        const stem = name[0 .. name.len - std.fs.path.extension(name).len];
        const host = try std.fmt.allocPrint(arena, "{s}/{s}_host.c", .{ dir, stem });
        const has_host = if (cwd.access(io, host, .{})) |_| true else |_| false;
        const hosts: []const []const u8 = if (has_host) &.{host} else &.{};
        const source = cwd.readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch "";
        const want = expectOutputOf(source);

        const outcome: Outcome = switch (try runProgram(init, cwd, path, hosts, true, err_w)) {
            .compile_failed => .failed_compile,
            .ran => |r| switch (r.term) {
                .exited => |code| if (code != 0) Outcome{ .failed_exit = code } else if (want) |w| blk: {
                    const got = std.mem.trimEnd(u8, r.stdout, "\n");
                    break :blk if (std.mem.eql(u8, got, w)) Outcome.passed_matched else Outcome{ .failed_output = .{ .want = w, .got = got } };
                } else .passed,
                .signal => |sig| blk: {
                    const tag = @tagName(sig);
                    const sig_name = if (std.mem.startsWith(u8, tag, "SIG")) tag else try std.fmt.allocPrint(arena, "SIG{s}", .{tag});
                    break :blk Outcome{ .failed_signal = .{ .name = sig_name, .signo = @truncate(@as(u32, @backingInt(sig))) } };
                },
                else => Outcome{ .failed_exit = 1 },
            },
        };
        var line_buf: [512]u8 = undefined;
        try out_w.print("{s}\n", .{reportLine(&line_buf, name, outcome)});
        switch (outcome) {
            .passed, .passed_matched => passed += 1,
            else => failed += 1,
        }
    }
    try out_w.print("{d} passed, {d} failed\n", .{ passed, failed });
    return if (failed == 0) 0 else 1;
}

/// Load (including stem pairing) and typecheck, rendering diagnostics to
/// `fw`. Returns `error.TypeError` when the bag has errors or pairing fails,
/// so the caller can exit 1 without a Zig stack trace after the caret.
fn loadAndReport(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    fw: *Io.File.Writer,
) !cell.ast.Module {
    const module = cell.loadAndCheck(allocator, io, dir, path, &fw.interface) catch |err| {
        try fw.interface.flush();
        return err;
    };
    try fw.interface.flush();
    return module;
}

fn printUsage(io: Io) !void {
    var buf: [1024]u8 = undefined;
    var fw: Io.File.Writer = .init(.stderr(), io, &buf);
    try fw.interface.writeAll(Usage);
    try fw.interface.flush();
}

/// The command names the usage text documents, in order. Parses the block
/// between "COMMANDS:" and the blank line before "OPTIONS:", taking the
/// first whitespace-delimited token of each line. Written as a parser rather
/// than a second hardcoded list on purpose: a hardcoded list would agree
/// with the enum while the help text quietly drifted from both.
fn usageCommands(buf: *[16][]const u8) []const []const u8 {
    const start = std.mem.indexOf(u8, Usage, "COMMANDS:\n").? + "COMMANDS:\n".len;
    const rest = Usage[start..];
    const end = std.mem.indexOf(u8, rest, "\n\n").?;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, rest[0..end], '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0) continue;
        const cut = std.mem.indexOfAny(u8, trimmed, " ") orelse trimmed.len;
        buf[n] = trimmed[0..cut];
        n += 1;
    }
    return buf[0..n];
}

test "the usage text documents exactly the commands the dispatcher accepts" {
    // The contract this file can actually check without spawning the binary.
    // A command handled but undocumented is undiscoverable; one documented
    // but unhandled reaches "unknown command" and makes the help a liar.
    var buf: [16][]const u8 = undefined;
    const documented = usageCommands(&buf);
    const names = @typeInfo(Command).@"enum".field_names;
    try std.testing.expectEqual(names.len, documented.len);
    inline for (names) |name| {
        var found = false;
        for (documented) |d| {
            if (std.mem.eql(u8, d, name)) found = true;
        }
        if (!found) {
            std.debug.print("Command.{s} is not documented in the usage text\n", .{name});
            return error.UndocumentedCommand;
        }
    }
    // And the converse: nothing documented that parseCommand rejects.
    for (documented) |d| {
        if (parseCommand(d) == null) {
            std.debug.print("usage documents '{s}', which parseCommand rejects\n", .{d});
            return error.UndispatchedCommand;
        }
    }
}

test "parseCommand maps every spelling, including the short aliases" {
    // The aliases have no other test. A `-V` that stopped meaning version
    // would otherwise fall through to the unknown-command branch silently.
    try std.testing.expectEqual(Command.help, parseCommand("help").?);
    try std.testing.expectEqual(Command.help, parseCommand("-h").?);
    try std.testing.expectEqual(Command.help, parseCommand("--help").?);
    try std.testing.expectEqual(Command.version, parseCommand("version").?);
    try std.testing.expectEqual(Command.version, parseCommand("-V").?);
    try std.testing.expectEqual(Command.check, parseCommand("check").?);
    try std.testing.expectEqual(Command.dump, parseCommand("dump").?);
    try std.testing.expectEqual(Command.emit, parseCommand("emit").?);
    // `build` was a pinned rejection until 2026-09-16 (opening gap 5: no
    // .cell-to-executable path). Both halves of that gap are commands now.
    try std.testing.expectEqual(Command.build, parseCommand("build").?);
    try std.testing.expectEqual(Command.run, parseCommand("run").?);
    try std.testing.expectEqual(Command.@"test", parseCommand("test").?);

    // Rejections. `-v` lowercase is NOT an alias (it would be ambiguous with
    // a future verbose flag), and the enum's own tag syntax is not a command.
    try std.testing.expect(parseCommand("-v") == null);
    try std.testing.expect(parseCommand("") == null);
}

test "expectOutputOf reads the corpus convention" {
    try std.testing.expectEqualStrings("42", expectOutputOf("// a\n// EXPECT-OUTPUT: 42\npub fn main() {}\n").?);
    try std.testing.expectEqualStrings("hello world", expectOutputOf("// EXPECT-OUTPUT:   hello world  \n").?);
    try std.testing.expect(expectOutputOf("pub fn main() {}\n") == null);
    try std.testing.expect(expectOutputOf("// see EXPECT-OUTPUT: below\n") == null);
}

test "reportLine formats every outcome" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("ok    add.cell", reportLine(&buf, "add.cell", .passed));
    try std.testing.expectEqualStrings("ok    s.cell (output matched)", reportLine(&buf, "s.cell", .passed_matched));
    try std.testing.expectEqualStrings("FAIL  o.cell (exit 3)", reportLine(&buf, "o.cell", .{ .failed_exit = 3 }));
    try std.testing.expectEqualStrings("FAIL  o.cell (exit 134: program terminated by signal SIGABRT)", reportLine(&buf, "o.cell", .{ .failed_signal = .{ .name = "SIGABRT", .signo = 6 } }));
    try std.testing.expectEqualStrings("FAIL  p.cell (expected output '42', got '41')", reportLine(&buf, "p.cell", .{ .failed_output = .{ .want = "42", .got = "41" } }));
    try std.testing.expectEqualStrings("FAIL  q.cell (did not compile)", reportLine(&buf, "q.cell", .failed_compile));
}

test "parseArgs: the path, --target=, and -o are order-independent, and a second path is refused" {
    // The old loop silently dropped every positional after the first, which
    // for `build` would have meant `cell build a.cell b.cell` compiling a.cell
    // and saying nothing about b.cell. Refusing is the only honest answer.
    const a = parseArgs(&.{ "x.cell", "--target=llvm", "-o", "bin/x" });
    try std.testing.expectEqualStrings("x.cell", a.ok.path);
    try std.testing.expectEqual(cell.Target.llvm, a.ok.target);
    try std.testing.expectEqualStrings("bin/x", a.ok.out.?);

    const b = parseArgs(&.{ "-o", "bin/x", "x.cell" });
    try std.testing.expectEqualStrings("x.cell", b.ok.path);
    try std.testing.expectEqualStrings("bin/x", b.ok.out.?);
    try std.testing.expectEqual(cell.Target.c, b.ok.target);

    const c = parseArgs(&.{"x.cell"});
    try std.testing.expect(c.ok.out == null);
    try std.testing.expectEqual(@as(usize, 0), c.ok.hosts().len);

    // A positional with a `.c` extension is a host source, not a second
    // Cell file, wherever it appears; the cap is refused by name, never
    // truncated.
    const h = parseArgs(&.{ "examples/arc_host.c", "examples/arc.cell", "-o", "arc", "extra.c" });
    try std.testing.expectEqualStrings("examples/arc.cell", h.ok.path);
    try std.testing.expectEqual(@as(usize, 2), h.ok.hosts().len);
    try std.testing.expectEqualStrings("examples/arc_host.c", h.ok.hosts()[0]);
    try std.testing.expectEqualStrings("extra.c", h.ok.hosts()[1]);
    try std.testing.expect(parseArgs(&.{ "a.cell", "1.c", "2.c", "3.c", "4.c", "5.c", "6.c", "7.c", "8.c", "9.c" }) == .too_many_hosts);

    try std.testing.expectEqualStrings("b.cell", parseArgs(&.{ "a.cell", "b.cell" }).extra_positional);
    try std.testing.expectEqualStrings("wasm", parseArgs(&.{ "a.cell", "--target=wasm" }).unknown_target);
    try std.testing.expectEqualStrings("--verbose", parseArgs(&.{ "a.cell", "--verbose" }).unknown_option);
    try std.testing.expect(parseArgs(&.{ "a.cell", "-o" }) == .missing_out_value);
    try std.testing.expect(parseArgs(&.{"--target=c"}) == .missing_file);
    try std.testing.expect(parseArgs(&.{}) == .missing_file);
}

test "defaultOutput strips exactly the extensions load accepts and never names the source" {
    // `cell build geometry.cell` writes `geometry`. A path with no known
    // extension must not become its own output name, or cc would overwrite
    // the source; it gets `.out` appended instead.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][2][]const u8{
        .{ "examples/hello.cell", "examples/hello" },
        .{ "a.cel", "a" },
        .{ "geometry.body", "geometry" },
        .{ "geometry.bod", "geometry" },
        .{ "prog", "prog.out" },
        .{ "notes.txt", "notes.txt.out" },
    };
    for (cases) |case| {
        const got = try defaultOutput(arena, case[0]);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "ccArgv mirrors the gate's run_c recipe, with the runtime taken from the staging dir" {
    // tools/check.sh stage 6 compiles `cc -I runtime main.c runtime/cell_rt.c
    // -o out`. build stages the runtime it embeds into the same directory as
    // the emitted C, so the include path and the runtime source both point
    // there, and the user's checkout is never a dependency of their binary.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try ccArgv(arena, "clang", "/tmp/cell-build-1", "/tmp/cell-build-1/main.c", &.{}, "hello");
    const want = [_][]const u8{ "clang", "-I", "/tmp/cell-build-1", "/tmp/cell-build-1/main.c", "/tmp/cell-build-1/cell_rt.c", "-o", "hello" };
    try std.testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, g| try std.testing.expectEqualStrings(w, g);

    // Hosts sit between the emitted C and the runtime, run_c_host's order,
    // and pass through as given: cc inherits the cwd, so nothing is staged.
    const with_hosts = try ccArgv(arena, "cc", "/s", "/s/main.c", &.{ "examples/arc_host.c", "x.c" }, "arc");
    const want2 = [_][]const u8{ "cc", "-I", "/s", "/s/main.c", "examples/arc_host.c", "x.c", "/s/cell_rt.c", "-o", "arc" };
    try std.testing.expectEqual(want2.len, with_hosts.len);
    for (want2, with_hosts) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "host sources are refused outside build and run" {
    // `cell check foo.c` used to load foo.c as Cell source through load's
    // unknown-extension fallback. A `.c` positional is a host now, and only
    // the two commands that invoke cc can do anything with one.
    try std.testing.expect(hostRefusal(.build, 2) == null);
    try std.testing.expect(hostRefusal(.run, 1) == null);
    try std.testing.expect(hostRefusal(.check, 0) == null);
    try std.testing.expect(hostRefusal(.check, 1) != null);
    try std.testing.expect(hostRefusal(.emit, 1) != null);
    try std.testing.expect(hostRefusal(.dump, 3) != null);
}

test "build refuses the textual targets and points at emit" {
    // Only the C backend produces something cc can compile. The refusal
    // names the command that does produce llvm/mlir text, so the message
    // is a redirect rather than a dead end.
    try std.testing.expect(buildTargetRefusal(.c) == null);
    try std.testing.expect(std.mem.indexOf(u8, buildTargetRefusal(.llvm).?, "cell emit --target=llvm") != null);
    try std.testing.expect(std.mem.indexOf(u8, buildTargetRefusal(.mlir).?, "cell emit --target=mlir") != null);
}

test "the usage text documents exactly the targets parseTarget accepts" {
    // Same contract, one layer down: --target= is the only option this CLI
    // has, and its three values appear in three places (the usage text, the
    // parser, and cell.Target). This pins the first two together.
    const accepted = [_][]const u8{ "c", "llvm", "mlir" };
    for (accepted) |name| {
        if (parseTarget(name) == null) return error.TargetRejected;
        var needle_buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "--target={s}", .{name}) catch unreachable;
        if (std.mem.indexOf(u8, Usage, needle) == null) {
            std.debug.print("target '{s}' is accepted but undocumented\n", .{name});
            return error.UndocumentedTarget;
        }
    }
    // Every `--target=` the usage mentions must parse.
    var rest: []const u8 = Usage;
    while (std.mem.indexOf(u8, rest, "--target=")) |at| {
        rest = rest[at + "--target=".len ..];
        const cut = std.mem.indexOfAny(u8, rest, " \n") orelse rest.len;
        if (parseTarget(rest[0..cut]) == null) {
            std.debug.print("usage documents --target={s}, which parseTarget rejects\n", .{rest[0..cut]});
            return error.UndocumentedTargetValue;
        }
    }

    try std.testing.expect(parseTarget("wasm") == null);
    try std.testing.expect(parseTarget("") == null);
}
