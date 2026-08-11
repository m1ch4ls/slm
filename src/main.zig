const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const openai = @import("openai.zig");

const max_input_bytes = 16 * 1024 * 1024;
const skill = build_options.skill;

/// Owns process-level error reporting so expected failures do not print stack traces.
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        switch (err) {
            error.InvalidArguments,
            error.MissingEnvironmentVariable,
            error.MissingPrompt,
            error.ApiRequestFailed,
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
    const model = config.model orelse
        try envRequired(init, "OPENAI_MODEL");
    const api_key = init.minimal.environ.getAlloc(init.arena.allocator(), "OPENAI_API_KEY") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };

    var stdin_buffer: [8 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const input = try stdin_reader.interface.allocRemaining(allocator, .limited(max_input_bytes));
    defer allocator.free(input);

    const output = try openai.complete(allocator, init.io, .{
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .prompt = prompt,
        .input = input,
        .max_tokens = config.max_tokens,
    });
    defer allocator.free(output);

    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(init.io, output);
    if (output.len == 0 or output[output.len - 1] != '\n') {
        try stdout.writeStreamingAll(init.io, "\n");
    }
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
    \\
    \\EXAMPLES:
    \\    git diff | slm "summarize in 3 bullets"
    \\    ps aux | slm --model qwen "list only node processes"
    \\
;

test {
    _ = cli;
    _ = openai;
}

test "skill command requires an exact invocation" {
    try std.testing.expect(isSkillCommand(&.{ "slm", "skill" }));
    try std.testing.expect(!isSkillCommand(&.{ "slm", "skill", "extra" }));
    try std.testing.expect(!isSkillCommand(&.{ "slm", "--skill" }));
}
