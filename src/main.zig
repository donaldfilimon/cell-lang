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

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    if (args.len < 2) {
        try printUsage(io);
        std.process.exit(1);
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
        try printUsage(io);
        return;
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "-V")) {
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
            if (std.mem.eql(u8, name, "c")) {
                target = .c;
            } else if (std.mem.eql(u8, name, "llvm")) {
                target = .llvm;
            } else if (std.mem.eql(u8, name, "mlir")) {
                target = .mlir;
            } else {
                std.debug.print("error: unknown target '{s}' (want c, llvm or mlir)\n", .{name});
                std.process.exit(1);
            }
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

    if (std.mem.eql(u8, cmd, "check")) {
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

    if (std.mem.eql(u8, cmd, "dump")) {
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

    if (std.mem.eql(u8, cmd, "emit")) {
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

test "cli smoke" {
    try std.testing.expect(true);
}
