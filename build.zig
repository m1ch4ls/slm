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

    daemon.root_module.addIncludePath(llama_include);
    daemon.root_module.addLibraryPath(llama_build);

    // Link core llama.cpp libraries (shared libs required for GGML_BACKEND_DL)
    daemon.root_module.linkSystemLibrary("llama", .{});
    daemon.root_module.linkSystemLibrary("ggml", .{});
    daemon.root_module.linkSystemLibrary("ggml-base", .{});
    // Note: Backends (ggml-cpu, ggml-hip, etc.) are loaded dynamically at runtime
    // via ggml_backend_load_all_from_path() based on availability

    daemon.root_module.link_libc = true;

    // Set rpath so the binary can find libraries in the same directory
    // $ORIGIN is a special ELF value meaning "directory where the binary is located"
    daemon.root_module.addRPath(.{ .cwd_relative = "$ORIGIN/../lib" });
    daemon.root_module.addRPath(.{ .cwd_relative = "$ORIGIN" });

    b.installArtifact(daemon);

    const run_daemon = b.addRunArtifact(daemon);
    run_daemon.step.dependOn(b.getInstallStep());

    const daemon_step = b.step("daemon", "Run the SLM daemon");
    daemon_step.dependOn(&run_daemon.step);

    // Benchmark executable
    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });

    const benchmark = b.addExecutable(.{
        .name = "slm-benchmark",
        .root_module = benchmark_mod,
    });

    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) {
        benchmark.want_lto = false;
    }

    benchmark.root_module.addIncludePath(llama_include);
    benchmark.root_module.addLibraryPath(llama_build);

    // Link core llama.cpp libraries
    benchmark.root_module.linkSystemLibrary("llama", .{});
    benchmark.root_module.linkSystemLibrary("ggml", .{});
    benchmark.root_module.linkSystemLibrary("ggml-base", .{});

    benchmark.root_module.link_libc = true;

    // Set rpath so the binary can find libraries in the same directory
    benchmark.root_module.addRPath(.{ .cwd_relative = "$ORIGIN/../lib" });
    benchmark.root_module.addRPath(.{ .cwd_relative = "$ORIGIN" });

    b.installArtifact(benchmark);

    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_benchmark.addArgs(args);
    }

    const benchmark_step = b.step("benchmark", "Run inference benchmarks");
    benchmark_step.dependOn(&run_benchmark.step);

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
}
