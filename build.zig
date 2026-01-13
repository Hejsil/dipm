const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug symbols") orelse false;
    const filters = b.option([]const []const u8, "filter", "Test filter") orelse &.{};

    const spaghet = b.dependency("spaghet", .{});

    const dipm_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "spaghet", .module = spaghet.module("spaghet") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "dipm",
        .root_module = dipm_module,
    });
    b.installArtifact(exe);

    const exe_unit_tests = b.addTest(.{
        .root_module = dipm_module,
        .filters = filters,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
