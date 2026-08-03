const std = @import("std");
const builtin = @import("builtin");

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

    // Zwanzig's analyzer and build.zig are not Zig 0.16 compatible
    // (std.fs was removed). Gate the dependency to <0.16; on 0.16 the lint
    // step only runs the dogfood import check.
    if (comptime builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16) {
        const lint_step = b.step("lint", "Run zsort check-imports on the repo");
        lint_step.dependOn(&check_imports.step);
    } else {
        if (b.lazyDependency("zwanzig", .{
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        })) |zwanzig| {
            const run_zwanzig = b.addRunArtifact(zwanzig.artifact("zwanzig"));
            run_zwanzig.setCwd(b.path("."));

            run_zwanzig.addArgs(&.{ "src", "build.zig" });
            const lint_step = b.step("lint", "Run Zwanzig on the whole repo");
            lint_step.dependOn(&run_zwanzig.step);
            lint_step.dependOn(&check_imports.step);
        }
    }

    // `zig build check` is not built-in on 0.15.2; define a compile-only step
    // covering the exe, the library module, and the tests.
    const lib_check = b.addObject(.{ .name = "zsort-lib", .root_module = zsort_module });
    const check_step = b.step("check", "Compile all targets without running");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&lib_check.step);
    check_step.dependOn(&tests.step);
}
