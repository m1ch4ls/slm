const std = @import("std");
const llama = @import("llama_api.zig");
const inference = @import("inference.zig");
const daemon = @import("daemon.zig");

const log = std.log.scoped(.benchmark);

/// Context for collecting output during benchmark
const BenchmarkContext = struct {
    output: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !BenchmarkContext {
        return .{
            .output = try std.ArrayList(u8).initCapacity(allocator, 4096),
            .allocator = allocator,
        };
    }

    fn deinit(self: *BenchmarkContext) void {
        self.output.deinit(self.allocator);
    }
};

/// Callback that collects output
fn benchmarkTokenCallback(chunk: []const u8, userdata: ?*anyopaque) bool {
    const ctx = @as(*BenchmarkContext, @ptrCast(@alignCast(userdata.?)));
    ctx.output.appendSlice(ctx.allocator, chunk) catch |err| {
        log.err("Failed to append output: {}", .{err});
        return false;
    };
    return true;
}

/// Results from a single benchmark run
const BenchmarkResult = struct {
    prompt_name: []const u8,
    prompt_tokens: usize,
    generated_tokens: usize,
    total_tokens: usize,
    elapsed_ms: u64,
    tokens_per_second: f64,
    prefill_tokens_per_second: f64,
    stopped_by_eos: bool,
    hit_token_limit: bool,
};

/// Print benchmark results in a formatted table
fn printResults(results: []const BenchmarkResult) void {
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    // Print header
    writer.print("\n{s:-^100}\n", .{" BENCHMARK RESULTS "}) catch {};
    writer.print("{s:20} {s:>12} {s:>12} {s:>12} {s:>12} {s:>12} {s:>8}\n", .{
        "Prompt",
        "Prompt Tok",
        "Gen Tok",
        "Time(ms)",
        "Tok/s",
        "Prefill/s",
        "Status",
    }) catch {};
    writer.print("{s:-^100}\n", .{""}) catch {};

    // Print results
    for (results) |r| {
        const status = if (r.stopped_by_eos)
            "EOS"
        else if (r.hit_token_limit)
            "LIMIT"
        else
            "OK";

        writer.print("{s:20} {d:>12} {d:>12} {d:>12} {d:>11.2} {d:>11.2} {s:>8}\n", .{
            r.prompt_name,
            r.prompt_tokens,
            r.generated_tokens,
            r.elapsed_ms,
            r.tokens_per_second,
            r.prefill_tokens_per_second,
            status,
        }) catch {};
    }

    // Print summary
    writer.print("{s:-^100}\n", .{""}) catch {};

    // Calculate averages
    var total_tok_per_sec: f64 = 0;
    var total_prefill_per_sec: f64 = 0;
    const count: f64 = @floatFromInt(results.len);

    for (results) |r| {
        total_tok_per_sec += r.tokens_per_second;
        total_prefill_per_sec += r.prefill_tokens_per_second;
    }

    writer.print("\nAverage tokens/sec:      {d:.2}\n", .{total_tok_per_sec / count}) catch {};
    writer.print("Average prefill tok/s:   {d:.2}\n", .{total_prefill_per_sec / count}) catch {};

    // Write to stdout using std.debug.print
    std.debug.print("{s}", .{fbs.getWritten()});
}

/// Run benchmark with a single prompt
fn runBenchmark(
    allocator: std.mem.Allocator,
    engine: *inference.InferenceEngine,
    name: []const u8,
    prompt: []const u8,
    max_tokens: u32,
) !BenchmarkResult {
    log.info("Running benchmark: {s}", .{name});

    var ctx = try BenchmarkContext.init(allocator);
    defer ctx.deinit();

    const options = inference.InferenceOptions{
        .max_tokens = max_tokens,
        .use_chat_template = true,
        .filter_think_blocks = true,
    };

    const start = std.time.milliTimestamp();
    const stats = try engine.generate(
        prompt,
        "", // no stdin
        options,
        benchmarkTokenCallback,
        &ctx,
    );
    const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));

    // Calculate prefill speed (prompt tokens / prefill time)
    // We approximate prefill time as proportional to prompt size
    // For simplicity, we use: prefill_time = total_time * (prompt_tokens / total_tokens)
    const total_tokens_f = @as(f64, @floatFromInt(stats.total_tokens));
    const prompt_tokens_f = @as(f64, @floatFromInt(stats.prompt_tokens));
    const elapsed_f = @as(f64, @floatFromInt(elapsed));

    const prefill_ratio = prompt_tokens_f / total_tokens_f;
    const prefill_time_ms = elapsed_f * prefill_ratio;
    const prefill_tok_per_sec = if (prefill_time_ms > 0)
        prompt_tokens_f / (prefill_time_ms / 1000.0)
    else
        0.0;

    log.info("  Prompt: {d} tokens", .{stats.prompt_tokens});
    log.info("  Generated: {d} tokens in {d}ms", .{ stats.generated_tokens, elapsed });
    log.info("  Speed: {d:.2} tok/s", .{stats.tokens_per_second});

    return BenchmarkResult{
        .prompt_name = name,
        .prompt_tokens = stats.prompt_tokens,
        .generated_tokens = stats.generated_tokens,
        .total_tokens = stats.total_tokens,
        .elapsed_ms = elapsed,
        .tokens_per_second = stats.tokens_per_second,
        .prefill_tokens_per_second = prefill_tok_per_sec,
        .stopped_by_eos = stats.stopped_by_eos,
        .hit_token_limit = stats.hit_token_limit,
    };
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var max_tokens: u32 = 1024; // Increased default for long outputs
    var warmup_runs: u32 = 1;
    var benchmark_runs: u32 = 3;
    var context_size: u32 = 65536; // 64k context
    var n_batch: u32 = 2048; // Larger batches for better throughput
    var flash_attn: bool = true; // Enable flash attention by default
    var n_threads: u32 = 16; // Use all cores on Ryzen 9 7950X

    // Simple arg parsing
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--tokens") or std.mem.eql(u8, args[i], "-t")) {
            i += 1;
            if (i < args.len) {
                max_tokens = std.fmt.parseInt(u32, args[i], 10) catch max_tokens;
            }
        } else if (std.mem.eql(u8, args[i], "--warmup") or std.mem.eql(u8, args[i], "-w")) {
            i += 1;
            if (i < args.len) {
                warmup_runs = std.fmt.parseInt(u32, args[i], 10) catch warmup_runs;
            }
        } else if (std.mem.eql(u8, args[i], "--runs") or std.mem.eql(u8, args[i], "-r")) {
            i += 1;
            if (i < args.len) {
                benchmark_runs = std.fmt.parseInt(u32, args[i], 10) catch benchmark_runs;
            }
        } else if (std.mem.eql(u8, args[i], "--context") or std.mem.eql(u8, args[i], "-c")) {
            i += 1;
            if (i < args.len) {
                context_size = std.fmt.parseInt(u32, args[i], 10) catch context_size;
            }
        } else if (std.mem.eql(u8, args[i], "--batch") or std.mem.eql(u8, args[i], "-b")) {
            i += 1;
            if (i < args.len) {
                n_batch = std.fmt.parseInt(u32, args[i], 10) catch n_batch;
            }
        } else if (std.mem.eql(u8, args[i], "--flash-attn") or std.mem.eql(u8, args[i], "-f")) {
            i += 1;
            if (i < args.len) {
                const val = args[i];
                flash_attn = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "on");
            }
        } else if (std.mem.eql(u8, args[i], "--threads") or std.mem.eql(u8, args[i], "-n")) {
            i += 1;
            if (i < args.len) {
                n_threads = std.fmt.parseInt(u32, args[i], 10) catch n_threads;
            }
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            var buf: [4096]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            var writer = fbs.writer();
            try writer.print("SLM Inference Benchmark - Performance Tuned\n\n", .{});
            try writer.print("Usage: slm-benchmark [options]\n\n", .{});
            try writer.print("Performance Options:\n", .{});
            try writer.print("  -c, --context <n>    Context size (default: 65536 for 64k)\n", .{});
            try writer.print("  -t, --tokens <n>     Max tokens to generate (default: 1024)\n", .{});
            try writer.print("  -b, --batch <n>      Batch size (default: 2048)\n", .{});
            try writer.print("  -f, --flash-attn <bool>  Enable flash attention (default: true)\n", .{});
            try writer.print("  -n, --threads <n>    Number of CPU threads (default: 16)\n", .{});
            try writer.print("\nBenchmark Options:\n", .{});
            try writer.print("  -w, --warmup <n>     Number of warmup runs (default: 1)\n", .{});
            try writer.print("  -r, --runs <n>       Number of benchmark runs (default: 3)\n", .{});
            try writer.print("  -h, --help           Show this help\n", .{});
            try writer.print("\nRecommended for max performance:\n", .{});
            try writer.print("  slm-benchmark -c 65536 -t 1024 -b 2048 -n 16\n", .{});
            std.debug.print("{s}", .{fbs.getWritten()});
            return;
        }
    }

    log.info("Configuration:", .{});
    log.info("  Context size: {d}", .{context_size});
    log.info("  Max tokens: {d}", .{max_tokens});
    log.info("  Batch size: {d}", .{n_batch});
    log.info("  Flash attention: {}", .{flash_attn});
    log.info("  Threads: {d}", .{n_threads});
    log.info("  Warmup runs: {d}", .{warmup_runs});
    log.info("  Benchmark runs: {d}", .{benchmark_runs});

    // Load config from same location as daemon
    var config = try daemon.readConfig(allocator);
    defer config.deinit();

    log.info("Loading model from {s}", .{config.model_path});

    // Load dynamic backends
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lib_path_allocated: ?[*:0]const u8, const lib_path: [*:0]const u8 = if (std.fs.selfExeDirPath(&exe_dir_buf)) |exe_dir| blk: {
        const p = std.fs.path.joinZ(allocator, &[_][]const u8{ exe_dir, "lib" }) catch |err| {
            log.warn("Could not construct lib path: {s}", .{@errorName(err)});
            break :blk .{ null, "/home/m1ch4ls/play/token-saver/llama.cpp/build/bin" };
        };
        break :blk .{ p, p };
    } else |err| blk: {
        log.warn("Could not determine executable directory: {s}", .{@errorName(err)});
        break :blk .{ null, "/home/m1ch4ls/play/token-saver/llama.cpp/build/bin" };
    };
    defer if (lib_path_allocated) |p| allocator.free(std.mem.span(p));

    const backend_paths = &[_][*:0]const u8{
        lib_path,
        "/home/m1ch4ls/play/token-saver/llama.cpp/build/bin",
    };

    for (backend_paths) |path| {
        log.info("Loading backends from: {s}", .{path});
        llama.ggml_backend_load_all_from_path(path);
    }

    // Initialize llama
    llama.llama_backend_init();
    defer llama.llama_backend_free();

    // Load model
    var model_params = llama.llama_model_default_params();
    model_params.n_gpu_layers = config.n_gpu_layers;
    model_params.split_mode = 0;
    model_params.main_gpu = config.main_gpu;

    var model = try llama.ModelHandle.load(allocator, config.model_path, model_params);
    defer model.deinit();

    // Create context with performance-tuned parameters
    var ctx = try llama.ContextHandle.init(&model, context_size, n_threads, n_batch, flash_attn);
    defer ctx.deinit();

    log.info("Model loaded successfully", .{});
    log.info("  Context: {d} tokens", .{context_size});
    log.info("  Batch: {d}, Flash attention: {}", .{ n_batch, flash_attn });
    log.info("  Threads: {d}", .{n_threads});

    // Create inference engine
    var engine = inference.InferenceEngine.init(allocator, &model, &ctx);

    // Define benchmark prompts
    const Prompt = struct {
        name: []const u8,
        text: []const u8,
    };

    const prompts = [_]Prompt{
        .{
            .name = "Short Q&A",
            .text = "What is the capital of France?",
        },
        .{
            .name = "Code Generation",
            .text = "Write a Python function to calculate the factorial of a number.",
        },
        .{
            .name = "Explanation",
            .text = "Explain the concept of recursion in programming with examples.",
        },
        .{
            .name = "Creative Writing",
            .text = "Write a short story about a robot learning to paint.",
        },
        .{
            .name = "Reasoning",
            .text = "If a train travels 60 miles in 1 hour, how far will it travel in 2.5 hours? Explain your reasoning.",
        },
    };

    // Warmup runs
    if (warmup_runs > 0) {
        log.info("\n--- Warmup ({d} runs) ---", .{warmup_runs});
        for (0..warmup_runs) |w| {
            log.info("Warmup run {d}/{d}...", .{ w + 1, warmup_runs });
            _ = runBenchmark(
                allocator,
                &engine,
                "warmup",
                prompts[0].text,
                32, // Short warmup
            ) catch |err| {
                log.warn("Warmup failed: {}", .{err});
            };
        }
    }

    // Benchmark runs
    var all_results = try std.ArrayList(BenchmarkResult).initCapacity(allocator, 16);
    defer all_results.deinit(allocator);

    log.info("\n--- Benchmark ({d} runs per prompt) ---", .{benchmark_runs});

    for (prompts) |prompt| {
        // Collect results for this prompt across multiple runs
        var prompt_results = try std.ArrayList(BenchmarkResult).initCapacity(allocator, benchmark_runs);
        defer prompt_results.deinit(allocator);

        for (0..benchmark_runs) |r| {
            log.info("Run {d}/{d} for '{s}'...", .{ r + 1, benchmark_runs, prompt.name });
            const result = runBenchmark(
                allocator,
                &engine,
                prompt.name,
                prompt.text,
                max_tokens,
            ) catch |err| {
                log.err("Benchmark failed for '{s}': {}", .{ prompt.name, err });
                continue;
            };
            try prompt_results.append(allocator, result);
        }

        // Average the results for this prompt
        if (prompt_results.items.len > 0) {
            var avg_result = prompt_results.items[0];
            avg_result.prompt_name = prompt.name;

            // Calculate averages
            var total_gen_tokens: usize = 0;
            var total_elapsed: u64 = 0;
            var total_tok_per_sec: f64 = 0;
            var total_prefill_per_sec: f64 = 0;

            for (prompt_results.items) |r| {
                total_gen_tokens += r.generated_tokens;
                total_elapsed += r.elapsed_ms;
                total_tok_per_sec += r.tokens_per_second;
                total_prefill_per_sec += r.prefill_tokens_per_second;
            }

            const n = @as(f64, @floatFromInt(prompt_results.items.len));
            avg_result.generated_tokens = total_gen_tokens / prompt_results.items.len;
            avg_result.elapsed_ms = total_elapsed / @as(u64, @intCast(prompt_results.items.len));
            avg_result.tokens_per_second = total_tok_per_sec / n;
            avg_result.prefill_tokens_per_second = total_prefill_per_sec / n;

            try all_results.append(allocator, avg_result);
        }
    }

    // Print results
    if (all_results.items.len > 0) {
        printResults(all_results.items);
    } else {
        log.err("No benchmark results collected!", .{});
    }
}
