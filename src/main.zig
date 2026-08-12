const std = @import("std");
const build_options = @import("build_options");
const attempt_store = @import("attempt_store.zig");
const cli = @import("cli.zig");
const config_module = @import("config.zig");
const limits = @import("limits.zig");
const model = @import("model.zig");
const model_manifest = @import("model_manifest.zig");
const openai = @import("openai.zig");
const source_input = @import("source_input.zig");

const skill = build_options.skill;

/// Owns process-level error reporting so expected failures do not print stack traces.
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        switch (err) {
            error.InvalidArguments,
            error.MissingPrompt,
            error.ModelFailureReported,
            error.SourceFailureReported,
            error.InvalidTaskInstruction,
            error.TaskInstructionTooLarge,
            error.ConfigurationFailure,
            => {},
            else => writeStderr(init.io, "slm: {s}\n", .{@errorName(err)}) catch {},
        }
        std.process.exit(1);
    };
}

/// Runs the slm CLI using Zig 0.16's process-provided I/O and environment.
fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (isSkillCommand(args)) {
        try std.Io.File.stdout().writeStreamingAll(init.io, skill);
        return;
    }

    const config = cli.parse(args) catch |err| {
        try writeStderr(init.io, "invalid arguments: {s}\n\n{s}", .{ @errorName(err), help });
        return error.InvalidArguments;
    };

    if (config.show_help) {
        try std.Io.File.stdout().writeStreamingAll(init.io, help);
        return;
    }

    if (config.debug_config and args.len != 2) {
        try writeStderr(init.io, "invalid arguments: --debug-config must be used alone\n", .{});
        return error.InvalidArguments;
    }

    const prompt = if (config.debug_config) null else config.prompt orelse {
        try writeStderr(init.io, "missing required argument: <prompt>\n\n{s}", .{help});
        return error.MissingPrompt;
    };
    if (prompt) |value| {
        if (!std.unicode.utf8ValidateSlice(value)) {
            try writeStderr(init.io, "slm: task instruction is not valid UTF-8\n", .{});
            return error.InvalidTaskInstruction;
        }
        if (value.len > limits.task_instruction_byte_limit) {
            try writeStderr(init.io, "slm: task instruction exceeds 16384 bytes\n", .{});
            return error.TaskInstructionTooLarge;
        }
    }

    const environment = try readConfigEnvironment(init);
    const resolved = cli_config: {
        const value = config_module.resolve(config, environment) catch |err| {
            if (config.debug_config) try writeInvalidDebugConfig(init.io, err) else try writeConfigurationError(init.io, err);
            return error.ConfigurationFailure;
        };
        break :cli_config value;
    };

    if (config.debug_config) {
        try writeDebugConfig(init.io, resolved);
        return;
    }

    const Request = struct { base_url: []const u8, model_id: []const u8, api_key: ?[]const u8, provider: ?[]const u8 };
    const request: Request = switch (resolved) {
        .explicit => |value| .{ .base_url = value.base_url, .model_id = value.model, .api_key = value.api_key, .provider = @as(?[]const u8, null) },
        .automatic => |value| automatic: {
            if (config.max_tokens > value.entry.output_limit) {
                try writeStderr(init.io, "slm: --max-tokens exceeds selected model output limit\n", .{});
                return error.ConfigurationFailure;
            }
            break :automatic .{ .base_url = value.provider.baseUrl(), .model_id = value.entry.model, .api_key = @as(?[]const u8, value.api_key), .provider = @as(?[]const u8, value.provider.id()) };
        },
    };

    const recording_enabled = try recordingEnabled(init);
    var store: ?attempt_store.Store = if (recording_enabled)
        try attempt_store.Store.open(allocator, init.io, .{
            .state_dir = try envOptional(init, "SLM_STATE_DIR"),
            .xdg_state_home = try envOptional(init, "XDG_STATE_HOME"),
            .home = try envOptional(init, "HOME"),
            .failure_point = try storageFailurePoint(init),
        })
    else
        null;
    defer if (store) |*value| value.close();

    const started_at_utc = if (recording_enabled)
        try formatUtcNow(allocator, init.io)
    else
        null;
    defer if (started_at_utc) |value| allocator.free(value);

    const monotonic_start = std.Io.Clock.awake.now(init.io);
    var attempt: ?attempt_store.Attempt = if (store) |*value|
        try value.begin(.{
            .task_instruction = prompt.?,
            .runtime_system_prompt = openai.system_prompt,
            .provider = request.provider,
            .model_id = request.model_id,
            .max_tokens = config.max_tokens,
        }, started_at_utc.?)
    else
        null;
    defer if (attempt) |*value| value.deinit();

    var stdin_buffer: [8 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var captured = if (attempt) |*value|
        try value.captureSource(&stdin_reader.interface)
    else
        try source_input.capture(allocator, &stdin_reader.interface, .{
            .processing_byte_limit = model.processing_byte_limit,
            .drain_oversized = false,
        });
    defer captured.deinit(allocator);
    const source_finished = std.Io.Clock.awake.now(init.io);
    const source_duration: u64 = @intCast(monotonic_start.durationTo(source_finished).nanoseconds);

    if (captured.too_large) {
        const durations: attempt_store.Durations = .{
            .source_ingestion = source_duration,
            .model_request = 0,
            .total = source_duration,
        };
        if (attempt) |*value| {
            try value.finalizeSourceInputTooLarge(durations);
            try writeStderr(init.io, "slm: source input too large (attempt {d})\n", .{value.attemptId()});
        } else {
            try writeStderr(init.io, "slm: source input too large\n", .{});
        }
        return error.SourceFailureReported;
    }
    if (!captured.utf8_valid) {
        const durations: attempt_store.Durations = .{
            .source_ingestion = source_duration,
            .model_request = 0,
            .total = source_duration,
        };
        if (attempt) |*value| {
            try value.finalizeSourceInputInvalid(durations);
            try writeStderr(init.io, "slm: source input is not valid UTF-8 (attempt {d})\n", .{value.attemptId()});
        } else {
            try writeStderr(init.io, "slm: source input is not valid UTF-8\n", .{});
        }
        return error.SourceFailureReported;
    }

    var result = try openai.complete(allocator, init.io, .{
        .base_url = request.base_url,
        .api_key = request.api_key,
        .model = request.model_id,
        .prompt = prompt.?,
        .input = captured.processable,
        .max_tokens = config.max_tokens,
    });
    defer result.deinit(allocator);
    const model_finished = std.Io.Clock.awake.now(init.io);
    const durations: attempt_store.Durations = .{
        .source_ingestion = source_duration,
        .model_request = @intCast(source_finished.durationTo(model_finished).nanoseconds),
        .total = @intCast(monotonic_start.durationTo(model_finished).nanoseconds),
    };

    switch (result) {
        .completion => |completion| {
            if (attempt) |*value| try value.finalizeCompleted(completion, durations);

            const output = completion.output.bytes();
            const stdout = std.Io.File.stdout();
            try stdout.writeStreamingAll(init.io, output);
            if (output.len == 0 or output[output.len - 1] != '\n') {
                try stdout.writeStreamingAll(init.io, "\n");
            }
        },
        .request_failed => |failure| {
            if (attempt) |*value| {
                try value.finalizeRequestFailed(failure, durations);
                try writeStderr(init.io, "slm: model request failed (attempt {d})\n", .{value.attemptId()});
            } else {
                try writeStderr(init.io, "slm: model request failed\n", .{});
            }
            return error.ModelFailureReported;
        },
        .response_invalid => |reason| {
            if (attempt) |*value| {
                try value.finalizeResponseInvalid(reason, durations);
                try writeStderr(init.io, "slm: invalid model response (attempt {d})\n", .{value.attemptId()});
            } else {
                try writeStderr(init.io, "slm: invalid model response\n", .{});
            }
            return error.ModelFailureReported;
        },
    }
}

fn recordingEnabled(init: std.process.Init) !bool {
    const value = try envOptional(init, "SLM_NO_RECORD") orelse return true;
    if (std.mem.eql(u8, value, "1")) return false;
    try writeStderr(init.io, "SLM_NO_RECORD must be exactly 1 when set\n", .{});
    return error.InvalidRecordingPolicy;
}

fn storageFailurePoint(init: std.process.Init) !?attempt_store.FailurePoint {
    const value = try envOptional(init, "SLM_TEST_STORAGE_FAILURE") orelse return null;
    return std.meta.stringToEnum(attempt_store.FailurePoint, value) orelse
        error.InvalidStorageFailurePoint;
}

fn envOptional(init: std.process.Init, name: []const u8) !?[]const u8 {
    return init.minimal.environ.getAlloc(init.arena.allocator(), name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
}

fn formatUtcNow(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const now = std.Io.Clock.real.now(io);
    if (now.nanoseconds < 0) return error.InvalidSystemTime;

    const seconds: u64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
    const milliseconds: u16 = @intCast(@divFloor(
        @mod(now.nanoseconds, std.time.ns_per_s),
        std.time.ns_per_ms,
    ));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            milliseconds,
        },
    );
}

fn isSkillCommand(args: []const []const u8) bool {
    return args.len == 2 and std.mem.eql(u8, args[1], "skill");
}

fn readConfigEnvironment(init: std.process.Init) !config_module.Environment {
    return .{
        .slm_base_url = try envOptional(init, "SLM_BASE_URL"),
        .slm_model = try envOptional(init, "SLM_MODEL"),
        .slm_api_key = try envOptional(init, "SLM_API_KEY"),
        .openai_api_key = try envOptional(init, "OPENAI_API_KEY"),
        .gemini_api_key = try envOptional(init, "GEMINI_API_KEY"),
        .anthropic_api_key = try envOptional(init, "ANTHROPIC_API_KEY"),
    };
}

fn writeConfigurationError(io: std.Io, err: config_module.ResolveError) !void {
    const message = switch (err) {
        error.IncompleteCliConfiguration => "--model and --base-url must be provided together",
        error.IncompleteEnvironmentConfiguration => "SLM_MODEL and SLM_BASE_URL must be set together",
        error.EmptyApiKey => "SLM_API_KEY must not be empty",
        error.EmptyProviderCredential => "provider credential variables must not be empty",
        error.NoProviderCredentials => "no provider credentials configured; set OPENAI_API_KEY, GEMINI_API_KEY, or ANTHROPIC_API_KEY, or set SLM_MODEL and SLM_BASE_URL",
        error.InvalidBaseUrl => "invalid compatibility base URL",
        error.InvalidModel => "invalid model ID",
    };
    try writeStderr(io, "slm: {s}\n", .{message});
}

fn writeInvalidDebugConfig(io: std.Io, err: config_module.ResolveError) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.print("status: invalid\nerror: {s}\n", .{@errorName(err)});
    try writer.interface.flush();
}

fn writeDebugConfig(io: std.Io, resolved: config_module.Resolved) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    switch (resolved) {
        .explicit => |value| try writer.interface.print(
            "status: valid\nmode: explicit\nprovider: unknown\nmodel: {s}\nbase_url: {s}\nauthentication: {s}\nselection: explicit environment\n",
            .{ value.model, value.base_url, if (value.api_key != null) "SLM_API_KEY" else "none" },
        ),
        .automatic => |value| try writer.interface.print(
            "status: valid\nmode: automatic\nprovider: {s}\nmodel: {s}\nbase_url: {s}\nauthentication: {s}\nselection: cheapest configured provider\n",
            .{ value.provider.label(), value.entry.model, value.provider.baseUrl(), value.provider.credentialVariable() },
        ),
    }
    if (resolved == .automatic) {
        const value = resolved.automatic;
        try writer.interface.writeAll("input_price: $");
        try writePrice(&writer.interface, value.entry.input_price);
        try writer.interface.writeAll(" / 1M tokens\noutput_price: $");
        try writePrice(&writer.interface, value.entry.output_price);
        try writer.interface.writeAll(" / 1M tokens\nestimated_cost: $");
        try writePrice(&writer.interface, value.entry.score() / 10);
        try writer.interface.print(" / 1M weighted tokens\ncatalog: models.dev\nmanifest_updated_at: {s}\n", .{model_manifest.updated_at});
    }
    try writer.interface.flush();
}

fn writePrice(writer: *std.Io.Writer, micro_usd: u64) !void {
    const fraction = micro_usd % 1_000_000;
    if (fraction == 0) return writer.print("{d}.00", .{micro_usd / 1_000_000});
    var digits: usize = 6;
    var trimmed = fraction;
    while (digits > 2 and trimmed % 10 == 0) : (digits -= 1) trimmed /= 10;
    try writer.print("{d}.", .{micro_usd / 1_000_000});
    switch (digits) {
        2 => try writer.print("{d:0>2}", .{trimmed}),
        3 => try writer.print("{d:0>3}", .{trimmed}),
        4 => try writer.print("{d:0>4}", .{trimmed}),
        5 => try writer.print("{d:0>5}", .{trimmed}),
        6 => try writer.print("{d:0>6}", .{trimmed}),
        else => unreachable,
    }
}

fn writeStderr(io: std.Io, comptime format: []const u8, args: anytype) !void {
    var buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(format, args);
    try writer.interface.flush();
}

const help =
    \\slm - pipe text through an OpenAI-compatible model
    \\
    \\USAGE:
    \\    slm [OPTIONS] <prompt>
    \\    slm skill
    \\
    \\OPTIONS:
    \\    -h, --help              Show this help
    \\    --model MODEL          Explicit model ID (requires --base-url)
    \\    --base-url URL         Explicit compatibility API root (requires --model)
    \\    --max-tokens N         Maximum generated tokens (default: 16384)
    \\    --debug-config        Show resolved environment configuration
    \\
    \\COMMANDS:
    \\    skill                  Print the agent skill
    \\
    \\ENVIRONMENT:
    \\    SLM_MODEL              Explicit model ID (with SLM_BASE_URL)
    \\    SLM_BASE_URL           Explicit compatibility API root
    \\    SLM_API_KEY            Optional explicit endpoint bearer token
    \\    OPENAI_API_KEY         OpenAI automatic-selection credential
    \\    GEMINI_API_KEY         Google Gemini automatic-selection credential
    \\    ANTHROPIC_API_KEY      Anthropic automatic-selection credential
    \\    SLM_STATE_DIR         Absolute Processing attempt store override
    \\    SLM_NO_RECORD=1       Disable Processing attempt recording
    \\
    \\EXAMPLES:
    \\    git diff | slm "summarize in 3 bullets"
    \\    ps aux | slm --model qwen "list only node processes"
    \\
;

test {
    _ = attempt_store;
    _ = cli;
    _ = config_module;
    _ = limits;
    _ = model;
    _ = model_manifest;
    _ = openai;
    _ = source_input;
}

test "skill command requires an exact invocation" {
    try std.testing.expect(isSkillCommand(&.{ "slm", "skill" }));
    try std.testing.expect(!isSkillCommand(&.{ "slm", "skill", "extra" }));
    try std.testing.expect(!isSkillCommand(&.{ "slm", "--skill" }));
}
