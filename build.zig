const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const executable = b.addExecutable(.{
        .name = "slm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "skill", @embedFile("SKILL.md"));
    executable.root_module.addOptions("build_options", build_options);
    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Run slm");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = executable.root_module });
    const run_tests = b.addRunArtifact(tests);

    const run_skill_test = b.addRunArtifact(executable);
    run_skill_test.addArg("skill");
    run_skill_test.clearEnvironment();
    run_skill_test.setStdIn(.{ .bytes = "ignored stdin" });
    run_skill_test.expectStdOutEqual(@embedFile("SKILL.md"));
    run_skill_test.expectStdErrEqual("");

    const run_process_test = b.addSystemCommand(&.{ "bun", "tests/process-success.js" });
    run_process_test.addArtifactArg(executable);

    const run_failure_process_test = b.addSystemCommand(&.{ "bun", "tests/process-failures.js" });
    run_failure_process_test.addArtifactArg(executable);

    const run_source_input_process_test = b.addSystemCommand(&.{ "bun", "tests/process-source-input.js" });
    run_source_input_process_test.addArtifactArg(executable);

    const run_store_hardening_test = b.addSystemCommand(&.{ "bun", "tests/process-store-hardening.js" });
    run_store_hardening_test.addArtifactArg(executable);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_skill_test.step);
    test_step.dependOn(&run_process_test.step);
    test_step.dependOn(&run_failure_process_test.step);
    test_step.dependOn(&run_source_input_process_test.step);
    test_step.dependOn(&run_store_hardening_test.step);
}
