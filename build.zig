const std = @import("std");

const zon = @import("build.zig.zon");
const src_version = @import("src/version.zig").version;
comptime {
    if (!std.mem.eql(u8, zon.version, src_version)) {
        @compileError("version drift: build.zig.zon says " ++ zon.version ++ " but src/version.zig says " ++ src_version);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zsort",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zsort.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const zsort_module = b.addModule("zsort", .{
        .root_source_file = b.path("src/zsort.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zsort_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const compat_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compat_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_compat_tests = b.addRunArtifact(compat_tests);
    test_step.dependOn(&run_compat_tests.step);

    const ast_scan_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ast_scan_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_ast_scan_tests = b.addRunArtifact(ast_scan_tests);
    test_step.dependOn(&run_ast_scan_tests.step);

    // Dogfood exe: always ReleaseFast — exercises the same binary users install
    // (zig build -Doptimize=ReleaseFast). Never installed. Host-targeted so the
    // run steps work regardless of -Dtarget. optimize lives on the module in
    // 0.15, so this needs its own module instance.
    const dogfood_module = b.createModule(.{
        .root_source_file = b.path("src/zsort.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const dogfood_exe = b.addExecutable(.{
        .name = "zsort-check",
        .root_module = dogfood_module,
    });

    // Enforce this repo's own conventions (no `./`- or `src/`-prefixed
    // imports) on itself, the same way the original project did.
    const check_imports = b.addRunArtifact(dogfood_exe);
    check_imports.setCwd(b.path("."));
    check_imports.addArgs(&.{ "check", "src", "--ban-prefix", "./", "--ban-prefix", "src/" });
    const check_imports_step = b.step("check-imports", "Run zsort check on its own source (dogfood)");
    check_imports_step.dependOn(&check_imports.step);

    const run_fix_imports = b.addRunArtifact(dogfood_exe);
    run_fix_imports.setCwd(b.path("."));
    run_fix_imports.addArgs(&.{ "fix", "src", "--ban-prefix", "./", "--ban-prefix", "src/" });
    const fix_imports_step = b.step("fix-imports", "Fix Zig import ordering in this repo");
    fix_imports_step.dependOn(&run_fix_imports.step);

    // `zig build check` is not built-in on 0.15.2; define a compile-only step
    // covering the exe, the library module, and the tests.
    const lib_check = b.addObject(.{ .name = "zsort-lib", .root_module = zsort_module });
    const check_step = b.step("check", "Compile all targets without running");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&lib_check.step);
    check_step.dependOn(&tests.step);
    check_step.dependOn(&compat_tests.step);
    check_step.dependOn(&ast_scan_tests.step);
}
