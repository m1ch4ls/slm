const std = @import("std");
const limits = @import("limits.zig");

pub const default_max_tokens = limits.default_max_tokens;

pub const Config = struct {
    prompt: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    model: ?[]const u8 = null,
    max_tokens: u32 = default_max_tokens,
    show_help: bool = false,
    debug_config: bool = false,
};

pub const ParseError = error{
    InvalidMaxTokens,
    MissingOptionValue,
    UnexpectedArgument,
    UnknownOption,
};

/// Parses slm's deliberately small command-line surface.
pub fn parse(args: []const []const u8) ParseError!Config {
    var config: Config = .{};

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            config.show_help = true;
        } else if (std.mem.eql(u8, arg, "--debug-config")) {
            config.debug_config = true;
        } else if (std.mem.eql(u8, arg, "--model")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            config.model = args[index];
        } else if (std.mem.startsWith(u8, arg, "--model=")) {
            config.model = try nonEmptyValue(arg, "--model=");
        } else if (std.mem.eql(u8, arg, "--base-url")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            config.base_url = args[index];
        } else if (std.mem.startsWith(u8, arg, "--base-url=")) {
            config.base_url = try nonEmptyValue(arg, "--base-url=");
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            config.max_tokens = try parseMaxTokens(args[index]);
        } else if (std.mem.startsWith(u8, arg, "--max-tokens=")) {
            config.max_tokens = try parseMaxTokens(try nonEmptyValue(arg, "--max-tokens="));
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else if (config.prompt == null) {
            config.prompt = arg;
        } else {
            return error.UnexpectedArgument;
        }
    }

    return config;
}

fn nonEmptyValue(arg: []const u8, prefix: []const u8) ParseError![]const u8 {
    const value = arg[prefix.len..];
    if (value.len == 0) return error.MissingOptionValue;
    return value;
}

fn parseMaxTokens(value: []const u8) ParseError!u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidMaxTokens;
    if (parsed == 0) return error.InvalidMaxTokens;
    return parsed;
}

test "parse accepts positional prompt and options" {
    const args = [_][]const u8{
        "slm",
        "--model=qwen",
        "--base-url",
        "http://localhost:11434/v1",
        "--max-tokens=256",
        "summarize",
    };

    const config = try parse(&args);

    try std.testing.expectEqualStrings("summarize", config.prompt.?);
    try std.testing.expectEqualStrings("qwen", config.model.?);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", config.base_url.?);
    try std.testing.expectEqual(@as(u32, 256), config.max_tokens);
}

test "parse rejects invalid arguments" {
    const unknown = [_][]const u8{ "slm", "--wat" };
    try std.testing.expectError(error.UnknownOption, parse(&unknown));

    const duplicate_prompt = [_][]const u8{ "slm", "first", "second" };
    try std.testing.expectError(error.UnexpectedArgument, parse(&duplicate_prompt));

    const zero_tokens = [_][]const u8{ "slm", "--max-tokens=0", "prompt" };
    try std.testing.expectError(error.InvalidMaxTokens, parse(&zero_tokens));
}
