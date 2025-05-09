const std = @import("std");

const LibraryModule = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");

    const lib_mods: []const LibraryModule = &[_]LibraryModule{
        .{ .name = "scanner", .root_source_file = b.path("src/lib.zig") },
    };

    for (lib_mods) |mod_def| {
        const mod = b.createModule(.{
            .root_source_file = mod_def.root_source_file,
            .target = target,
            .optimize = optimize,
        });

        const lib = b.addLibrary(.{
            .linkage = .static,
            .name = mod_def.name,
            .root_module = mod,
        });

        b.installArtifact(lib);

        const lib_unit_tests = b.addTest(.{
            .root_module = mod,
        });

        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

        test_step.dependOn(&run_lib_unit_tests.step);
    }
}
