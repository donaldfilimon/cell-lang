const std = @import("std");
const cell = @import("cell");
const Io = std.Io;

// C runtime ABI (Zig 0.17: no @cImport — declare externs)
extern fn cell_rt_version() [*:0]const u8;
extern fn cell_cxx_probe() c_int;
extern fn cell_swift_probe() c_int;

const Usage =
    \\cell — Cell language toolchain (Zig host)
    \\
    \\USAGE:
    \\  cell <command> [args]
    \\
    \\COMMANDS:
    \\  check <file.cell>     Parse + typecheck + borrow-check
    \\  dump  <file.cell>     Parse and print AST
    \\  emit  <file.cell>     Emit code (see --target)
    \\  version               Print version
    \\  help                  Show this help
    \\
    \\OPTIONS:
    \\  --target=c            Emit C against runtime/cell_rt.h (default)
    \\  --target=llvm         Emit textual LLVM IR
    \\  --target=mlir         Emit textual MLIR (func/arith/memref/scf)
    \\
    \\The llvm and mlir backends are scalar-first. A construct they cannot
    \\carry yet is reported as a `cannot lower` error at its span, not
    \\emitted as something that looks plausible.
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
/// through a switch on this enum, and checking the usage text against
/// `std.meta.fields` makes that drift a build failure instead.
const Command = enum { check, dump, emit, version, help };

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
        std.debug.print("runtime: {s}\n", .{cell_rt_version()});
        std.debug.print("cxx probe: {d}\n", .{cell_cxx_probe()});
        std.debug.print("swift probe: {d}\n", .{cell_swift_probe()});
        return;
    }

    if (args.len < 3) {
        std.debug.print("error: missing file argument\n\n", .{});
        try printUsage(io);
        std.process.exit(1);
    }
    // The first argument that is not a flag is the path, so `--target` may
    // appear on either side of it.
    var path: []const u8 = "";
    var target: cell.Target = .c;
    for (args[2..]) |a| {
        if (std.mem.startsWith(u8, a, "--target=")) {
            const name = a["--target=".len..];
            target = parseTarget(name) orelse {
                std.debug.print("error: unknown target '{s}' (want c, llvm or mlir)\n", .{name});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, a, "--")) {
            std.debug.print("error: unknown option '{s}'\n\n", .{a});
            try printUsage(io);
            std.process.exit(1);
        } else if (path.len == 0) {
            path = a;
        }
    }
    if (path.len == 0) {
        std.debug.print("error: missing file argument\n\n", .{});
        try printUsage(io);
        std.process.exit(1);
    }
    const cwd = Io.Dir.cwd();

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
        .check, .dump, .emit, .version, .help => unreachable,
    };

    std.debug.print("error: unknown command '{s}'\n\n", .{cmd});
    try printUsage(io);
    std.process.exit(1);
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
fn usageCommands(buf: *[8][]const u8) []const []const u8 {
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
    var buf: [8][]const u8 = undefined;
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

    // Rejections. `-v` lowercase is NOT an alias (it would be ambiguous with
    // a future verbose flag), and the enum's own tag syntax is not a command.
    try std.testing.expect(parseCommand("-v") == null);
    try std.testing.expect(parseCommand("build") == null);
    try std.testing.expect(parseCommand("") == null);
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
