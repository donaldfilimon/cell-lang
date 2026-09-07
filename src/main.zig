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
    \\  check <file.cell>     Parse + typecheck
    \\  dump  <file.cell>     Parse and print AST
    \\  emit  <file.cell>     Emit C ABI / IR sketch
    \\  version               Print version
    \\  help                  Show this help
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
    const path = args[2];
    const source = try readFile(arena, io, path);

    if (std.mem.eql(u8, cmd, "check")) {
        var module = try cell.compile(arena, source, path);
        defer module.deinit(arena);
        try checkAndReport(arena, io, &module, source);
        std.debug.print("ok: {s} ({d} items)\n", .{ path, module.items.len });
        return;
    }

    if (std.mem.eql(u8, cmd, "dump")) {
        var module = try cell.compile(arena, source, path);
        defer module.deinit(arena);
        var buf: [4096]u8 = undefined;
        var fw: Io.File.Writer = .init(.stderr(), io, &buf);
        try module.dump(&fw.interface);
        try fw.interface.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "emit")) {
        var module = try cell.compile(arena, source, path);
        defer module.deinit(arena);
        try checkAndReport(arena, io, &module, source);
        var buf: [8192]u8 = undefined;
        var fw: Io.File.Writer = .init(.stdout(), io, &buf);
        try cell.emit(arena, &module, &fw.interface);
        try fw.interface.flush();
        return;
    }

    std.debug.print("error: unknown command '{s}'\n\n", .{cmd});
    try printUsage(io);
    std.process.exit(1);
}

/// Typecheck and render the diagnostics to stderr, exiting 1 when any of them
/// is an error. Exiting here rather than propagating keeps the rendered caret
/// as the last thing the user sees, instead of a Zig error trace after it.
fn checkAndReport(
    allocator: std.mem.Allocator,
    io: Io,
    module: *cell.ast.Module,
    source: []const u8,
) !void {
    var buf: [4096]u8 = undefined;
    var fw: Io.File.Writer = .init(.stderr(), io, &buf);
    cell.check(allocator, module, source, &fw.interface) catch |err| {
        try fw.interface.flush();
        if (err == error.TypeError) std.process.exit(1);
        return err;
    };
    try fw.interface.flush();
}

fn printUsage(io: Io) !void {
    var buf: [1024]u8 = undefined;
    var fw: Io.File.Writer = .init(.stderr(), io, &buf);
    try fw.interface.writeAll(Usage);
    try fw.interface.flush();
}

fn readFile(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    return try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
}

test "cli smoke" {
    try std.testing.expect(true);
}
