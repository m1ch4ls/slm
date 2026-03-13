const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const llama_include = b.path("llama.cpp/include");
    const llama_build = b.path("llama.cpp/build/bin");

    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });

    const client = b.addExecutable(.{
        .name = "slm",
        .root_module = client_mod,
    });

    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) {
        client.want_lto = false;
    }

    b.installArtifact(client);

    const run_client = b.addRunArtifact(client);
    run_client.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_client.addArgs(args);
    }

    const run_step = b.step("run", "Run the SLM client");
    run_step.dependOn(&run_client.step);

    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });

    const daemon = b.addExecutable(.{
        .name = "slm-daemon",
        .root_module = daemon_mod,
    });

    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) {
        daemon.want_lto = false;
    }

    daemon.addIncludePath(llama_include);
    daemon.addLibraryPath(llama_build);

    daemon.linkSystemLibrary("llama");
    daemon.linkSystemLibrary("ggml");
    daemon.linkSystemLibrary("ggml-base");
    daemon.linkSystemLibrary("ggml-cpu");
    daemon.linkLibC();

    b.installArtifact(daemon);

    const run_daemon = b.addRunArtifact(daemon);
    run_daemon.step.dependOn(b.getInstallStep());

    const daemon_step = b.step("daemon", "Run the SLM daemon");
    daemon_step.dependOn(&run_daemon.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });

    const test_exe = b.addTest(.{
        .root_module = test_mod,
    });

    const run_test = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_test.step);

    const protocol_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protocol.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    const run_protocol_test = b.addRunArtifact(protocol_test);
    test_step.dependOn(&run_protocol_test.step);

    const tokenizer_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tokenizer.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    const run_tokenizer_test = b.addRunArtifact(tokenizer_test);
    test_step.dependOn(&run_tokenizer_test.step);

    const think_filter_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/think_filter_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    const run_think_filter_test = b.addRunArtifact(think_filter_test);
    test_step.dependOn(&run_think_filter_test.step);
}
