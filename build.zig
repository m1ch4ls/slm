const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Resolve llama.cpp library and include paths.
    // Priority: -Dllama_prefix=... > Homebrew (macOS) > local llama.cpp/build/bin
    const llama_prefix = b.option([]const u8, "llama_prefix", "Path to llama.cpp installation prefix (e.g. /usr, /opt/homebrew)");
    const llama_brew = if (llama_prefix == null) detectHomebrew(b) else null;

    const llama_lib_dir: []const u8 = if (llama_prefix) |p|
        b.pathJoin(&.{ p, "lib" })
    else if (llama_brew) |p|
        b.pathJoin(&.{ p, "lib" })
    else
        "llama.cpp/build/bin";

    const llama_lib_path: std.Build.LazyPath = .{ .cwd_relative = llama_lib_dir };

    const llama_include: std.Build.LazyPath = if (llama_prefix) |p|
        .{ .cwd_relative = b.pathJoin(&.{ p, "include" }) }
    else if (llama_brew) |p|
        .{ .cwd_relative = b.pathJoin(&.{ p, "include" }) }
    else
        b.path("llama.cpp/include");

    // Copy libllama / libggml libraries into zig-out/lib/ so the binaries
    // can find them at runtime via their $ORIGIN/../lib rpath.
    installLlamaLibs(b, llama_lib_dir);


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
    daemon.root_module.addLibraryPath(llama_lib_path);

    // Link core llama.cpp libraries (shared libs required for GGML_BACKEND_DL)
    daemon.root_module.linkSystemLibrary("llama", .{});
    daemon.root_module.linkSystemLibrary("ggml", .{});
    daemon.root_module.linkSystemLibrary("ggml-base", .{});
    // Note: Backends (ggml-cpu, ggml-hip, etc.) are loaded dynamically at runtime
    // via ggml_backend_load_all_from_path() based on availability

    daemon.root_module.link_libc = true;

    // Set rpath so the binary can find libraries in the same directory
    // Use addRPathSpecial to prevent Zig from normalizing $ORIGIN as a path component
    daemon.root_module.addRPathSpecial("$ORIGIN/../lib");
    daemon.root_module.addRPathSpecial("$ORIGIN");

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
    benchmark.root_module.addLibraryPath(llama_lib_path);

    // Link core llama.cpp libraries
    benchmark.root_module.linkSystemLibrary("llama", .{});
    benchmark.root_module.linkSystemLibrary("ggml", .{});
    benchmark.root_module.linkSystemLibrary("ggml-base", .{});

    benchmark.root_module.link_libc = true;

    // Set rpath so the binary can find libraries in the same directory
    // Use addRPathSpecial to prevent Zig from normalizing $ORIGIN as a path component
    benchmark.root_module.addRPathSpecial("$ORIGIN/../lib");
    benchmark.root_module.addRPathSpecial("$ORIGIN");

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

/// Copies libllama* and libggml* shared libraries into zig-out/lib/ so the
/// binaries find them at runtime via their $ORIGIN/../lib rpath.
///
/// On Homebrew installs, the loadable backends (libggml-cpu*.so, libggml-metal.so)
/// live in the Cellar's libexec/ rather than lib/. We resolve libggml.dylib's real
/// path to find the Cellar prefix and scan its libexec/ as well.
fn installLlamaLibs(b: *std.Build, lib_dir: []const u8) void {
    installLibsFromDir(b, lib_dir);

    // Resolve libggml.dylib -> real path -> Cellar prefix -> libexec/
    for (&[_][]const u8{ "libggml.dylib", "libggml.so" }) |name| {
        const link = b.pathJoin(&.{ lib_dir, name });
        if (std.fs.realpathAlloc(b.allocator, link)) |real| {
            defer b.allocator.free(real);
            // real = <cellar>/lib/libggml.X.Y.dylib  →  dirname twice = <cellar>
            if (std.fs.path.dirname(real)) |cellar_lib|
                if (std.fs.path.dirname(cellar_lib)) |cellar_prefix| {
                    installLibsFromDir(b, b.pathJoin(&.{ cellar_prefix, "libexec" }));
                };
            break;
        } else |_| {}
    }
}

fn installLibsFromDir(b: *std.Build, dir_path: []const u8) void {
    var dir = if (std.fs.path.isAbsolute(dir_path))
        std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return
    else
        std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const name = entry.name;
        if (!std.mem.startsWith(u8, name, "libllama") and
            !std.mem.startsWith(u8, name, "libggml")) continue;
        if (!std.mem.endsWith(u8, name, ".dylib") and
            !std.mem.endsWith(u8, name, ".so") and
            std.mem.indexOf(u8, name, ".so.") == null) continue;

        const src = b.pathJoin(&.{ dir_path, name });
        const dest = b.pathJoin(&.{ "lib", name });
        const step = b.addInstallFile(.{ .cwd_relative = src }, dest);
        b.getInstallStep().dependOn(&step.step);
    }
}

/// Returns the Homebrew prefix if llama.cpp is installed there, otherwise null.
/// Checks arm64 (/opt/homebrew) then Intel (/usr/local) prefixes.
fn detectHomebrew(b: *std.Build) ?[]const u8 {
    const candidates = [_][]const u8{ "/opt/homebrew", "/usr/local" };
    for (candidates) |prefix| {
        const lib = b.pathJoin(&.{ prefix, "lib", "libllama.dylib" });
        std.fs.accessAbsolute(lib, .{}) catch continue;
        return prefix;
    }
    return null;
}
