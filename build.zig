const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const accept_model_update = b.option(bool, "accept-model-update", "Accept generated model manifest and README changes") orelse false;

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

    const integration_options = b.addOptions();
    integration_options.addOptionPath("slm_path", executable.getEmittedBin());
    const integration = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration.root_module.addOptions("integration_options", integration_options);
    const run_integration = b.addRunArtifact(integration);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_skill_test.step);
    test_step.dependOn(&run_integration.step);

    const updater = b.addExecutable(.{
        .name = "update-models",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/update_models.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_updater = b.addRunArtifact(updater);
    if (accept_model_update) run_updater.addArg("--accept");
    const update_step = b.step("update-models", "Refresh the model manifest from models.dev");
    update_step.dependOn(&run_updater.step);
}
