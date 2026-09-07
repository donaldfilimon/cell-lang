const std = @import("std");

/// Cell-lang: multi-language host build (Zig + C + C++ + optional Swift).
/// Zig 0.17 build graph orchestrates all sources.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_swift = b.option(bool, "swift", "Link Swift interop bridge (macOS)") orelse true;
    const enable_cxx = b.option(bool, "cxx", "Link C++ runtime helpers") orelse true;

    const c_flags = [_][]const u8{ "-std=c11", "-Wall", "-Wextra" };
    const cxx_flags = [_][]const u8{ "-std=c++20", "-Wall", "-Wextra", "-fno-exceptions" };

    // ── Core library module (Zig only; C linked via exe/tests) ──────────
    const cell_mod = b.addModule("cell", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Compiler / CLI executable (Zig + C + C++ + optional Swift) ──────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "cell", .module = cell_mod },
        },
    });
    exe_mod.addIncludePath(b.path("runtime"));
    exe_mod.addCSourceFile(.{
        .file = b.path("runtime/cell_rt.c"),
        .flags = &c_flags,
    });
    if (enable_cxx) {
        exe_mod.addCSourceFile(.{
            .file = b.path("runtime/cell_rt.cpp"),
            .flags = &cxx_flags,
        });
        exe_mod.link_libcpp = true;
    }

    const exe = b.addExecutable(.{
        .name = "cell",
        .root_module = exe_mod,
    });

    // ── Swift bridge (macOS, optional) ──────────────────────────────────
    if (enable_swift and target.result.os.tag == .macos) {
        const swift_obj = ".cell-cache/swift/CellBridge.o";
        const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", ".cell-cache/swift" });
        const swiftc = b.addSystemCommand(&.{
            "swiftc",
            "-parse-as-library",
            "-emit-object",
            "-module-name",
            "CellBridge",
            "-I",
            "runtime",
        });
        switch (optimize) {
            .Debug => swiftc.addArg("-Onone"),
            .ReleaseSafe, .ReleaseFast => swiftc.addArg("-O"),
            .ReleaseSmall => swiftc.addArg("-Osize"),
        }
        swiftc.addArg("-o");
        swiftc.addArg(swift_obj);
        swiftc.addFileArg(b.path("swift/CellBridge.swift"));
        swiftc.step.dependOn(&mkdir.step);

        exe.step.dependOn(&swiftc.step);
        exe_mod.addObjectFile(.{ .cwd_relative = swift_obj });

        // Apple Swift runtime: SDK tbd stubs + dyld rpath
        exe_mod.addLibraryPath(.{
            .cwd_relative = "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/swift",
        });
        exe_mod.addLibraryPath(.{
            .cwd_relative = "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx",
        });
        exe_mod.addRPathSpecial("/usr/lib/swift");
        exe_mod.linkSystemLibrary("swiftCore", .{});
    }

    b.installArtifact(exe);

    // ── Run ─────────────────────────────────────────────────────────────
    const run_step = b.step("run", "Run the cell CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // ── Tests (library pure Zig + CLI with runtime) ─────────────────────
    const mod_tests = b.addTest(.{ .root_module = cell_mod });

    const test_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "cell", .module = cell_mod },
        },
    });
    test_exe_mod.addIncludePath(b.path("runtime"));
    test_exe_mod.addCSourceFile(.{
        .file = b.path("runtime/cell_rt.c"),
        .flags = &c_flags,
    });
    if (enable_cxx) {
        test_exe_mod.addCSourceFile(.{
            .file = b.path("runtime/cell_rt.cpp"),
            .flags = &cxx_flags,
        });
        test_exe_mod.link_libcpp = true;
    }
    const exe_tests = b.addTest(.{ .root_module = test_exe_mod });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // ── C runtime ABI tests (pure C harness, warnings are errors) ────────
    // cell_rt.cpp is deliberately not linked here, so the weak-symbol
    // fallbacks for cell_cxx_probe / cell_swift_probe are exercised.
    const rt_test_flags = [_][]const u8{ "-std=c11", "-Wall", "-Wextra", "-Werror" };
    const rt_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    rt_test_mod.addIncludePath(b.path("runtime"));
    rt_test_mod.addCSourceFile(.{
        .file = b.path("runtime/cell_rt.c"),
        .flags = &rt_test_flags,
    });
    rt_test_mod.addCSourceFile(.{
        .file = b.path("runtime/tests/test_cell_rt.c"),
        .flags = &rt_test_flags,
    });
    const rt_tests = b.addExecutable(.{
        .name = "cell-rt-tests",
        .root_module = rt_test_mod,
    });
    const run_rt_tests = b.addRunArtifact(rt_tests);
    const rt_test_step = b.step("test-runtime", "Run the C runtime ABI tests");
    rt_test_step.dependOn(&run_rt_tests.step);
    test_step.dependOn(&run_rt_tests.step);

    // ── Examples ────────────────────────────────────────────────────────
    const examples_step = b.step("examples", "Typecheck example .cell files");
    const run_examples = b.addRunArtifact(exe);
    run_examples.addArgs(&.{ "check", "examples/hello.cell" });
    run_examples.step.dependOn(b.getInstallStep());
    examples_step.dependOn(&run_examples.step);
}
