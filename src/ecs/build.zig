//! The engine as a package: one module, `ecs`, rooted at `root.zig`, and a `test` step for the
//! engine's own tests. It depends on nothing but `std`. A host adds the module to its own
//! (`b.dependency("ecs", ...).module("ecs")`) and imports it as `@import("ecs")`.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ecs = b.addModule("ecs", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = ecs, .use_llvm = true });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the engine's unit tests");
    test_step.dependOn(&run_tests.step);
}
