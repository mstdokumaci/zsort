const std = @import("std");

pub fn build(b: *std.Build) void {
    // This is the consumer-facing setup documented in the README: zsort is a
    // lazy dependency, so it is only fetched and built when one of the steps
    // below is actually run.
    const zsort = b.lazyDependency("zsort", .{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    if (zsort) |dep| {
        const zsort_exe = dep.artifact("zsort");

        const check_imports = b.addRunArtifact(zsort_exe);
        check_imports.setCwd(b.path("."));
        check_imports.addArgs(&.{ "check", "src", "--ban-prefix", "./", "--ban-prefix", "src/" });
        const check_imports_step = b.step("check-imports", "Run zsort check on this project");
        check_imports_step.dependOn(&check_imports.step);

        const run_fix_imports = b.addRunArtifact(zsort_exe);
        run_fix_imports.setCwd(b.path("."));
        run_fix_imports.addArgs(&.{ "fix", "src", "--ban-prefix", "./", "--ban-prefix", "src/" });
        const fix_imports_step = b.step("fix-imports", "Fix Zig import ordering in this project");
        fix_imports_step.dependOn(&run_fix_imports.step);
    }
}
