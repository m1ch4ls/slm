const std = @import("std");
const build_options = @import("build_options");
const attempt_store = @import("attempt_store.zig");
const cli = @import("cli.zig");
const model = @import("model.zig");
const openai = @import("openai.zig");

const skill = build_options.skill;

/// Owns process-level error reporting so expected failures do not print stack traces.
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        switch (err) {
            error.InvalidArguments,
            error.MissingEnvironmentVariable,
            error.MissingPrompt,
            error.ModelFailureReported,
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

    const prompt = config.prompt orelse {
        try writeStderr(init.io, "missing required argument: <prompt>\n\n{s}", .{help});
        return error.MissingPrompt;
    };

    const base_url = config.base_url orelse
        try envOrDefault(init, "OPENAI_BASE_URL", cli.default_base_url);
    const model_id = config.model orelse
        try envRequired(init, "OPENAI_MODEL");
    const api_key = init.minimal.environ.getAlloc(init.arena.allocator(), "OPENAI_API_KEY") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };

    const recording_enabled = try recordingEnabled(init);
    var store: ?attempt_store.Store = if (recording_enabled)
        try attempt_store.Store.open(allocator, init.io, .{
            .state_dir = try envOptional(init, "SLM_STATE_DIR"),
            .xdg_state_home = try envOptional(init, "XDG_STATE_HOME"),
            .home = try envOptional(init, "HOME"),
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
            .task_instruction = prompt,
            .runtime_system_prompt = openai.system_prompt,
            .model_id = model_id,
            .max_tokens = config.max_tokens,
        }, started_at_utc.?)
    else
        null;
    defer if (attempt) |*value| value.deinit();

    var stdin_buffer: [8 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const input = try stdin_reader.interface.allocRemaining(allocator, .limited(model.processing_byte_limit));
    defer allocator.free(input);
    if (attempt) |*value| try value.captureSource(input);
    const source_finished = std.Io.Clock.awake.now(init.io);

    var result = try openai.complete(allocator, init.io, .{
        .base_url = base_url,
        .api_key = api_key,
        .model = model_id,
        .prompt = prompt,
        .input = input,
        .max_tokens = config.max_tokens,
    });
    defer result.deinit(allocator);
    const model_finished = std.Io.Clock.awake.now(init.io);
    const durations: attempt_store.Durations = .{
        .source_ingestion = @intCast(monotonic_start.durationTo(source_finished).nanoseconds),
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

fn envOrDefault(init: std.process.Init, name: []const u8, default: []const u8) ![]const u8 {
    return init.minimal.environ.getAlloc(init.arena.allocator(), name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => default,
        else => return err,
    };
}

fn envRequired(init: std.process.Init, name: []const u8) ![]const u8 {
    return init.minimal.environ.getAlloc(init.arena.allocator(), name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            try writeStderr(init.io, "missing required environment variable: {s}\n", .{name});
            return error.MissingEnvironmentVariable;
        },
        else => return err,
    };
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
    \\    --model MODEL          Model ID (or OPENAI_MODEL)
    \\    --base-url URL         API base URL (or OPENAI_BASE_URL)
    \\                           Default: https://api.openai.com/v1
    \\    --max-tokens N         Maximum generated tokens (default: 16384)
    \\
    \\COMMANDS:
    \\    skill                  Print the agent skill
    \\
    \\ENVIRONMENT:
    \\    OPENAI_MODEL           Required unless --model is passed
    \\    OPENAI_BASE_URL        OpenAI-compatible API base URL
    \\    OPENAI_API_KEY         Optional bearer token
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
    _ = model;
    _ = openai;
}

test "skill command requires an exact invocation" {
    try std.testing.expect(isSkillCommand(&.{ "slm", "skill" }));
    try std.testing.expect(!isSkillCommand(&.{ "slm", "skill", "extra" }));
    try std.testing.expect(!isSkillCommand(&.{ "slm", "--skill" }));
}
