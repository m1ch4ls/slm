const std = @import("std");
const model = @import("model.zig");

pub const system_prompt = @embedFile("system.txt");

pub const RequestOptions = struct {
    base_url: []const u8,
    api_key: ?[]const u8,
    model: []const u8,
    prompt: []const u8,
    input: []const u8,
    max_tokens: u32,
};

const Message = struct {
    role: []const u8,
    content: []const u8,
};

const CompletionResponse = struct {
    choices: []const Choice,
    usage: ?Usage = null,

    const Choice = struct {
        finish_reason: ?[]const u8 = null,
        message: struct {
            content: ?[]const u8 = null,
            refusal: ?[]const u8 = null,
        },
    };

    const Usage = struct {
        prompt_tokens: ?u64 = null,
        completion_tokens: ?u64 = null,
        total_tokens: ?u64 = null,
    };
};

/// Calls an OpenAI-compatible chat completions endpoint and returns an owned completion.
pub fn complete(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RequestOptions,
) !model.CompletionResult {
    const user_content = try formatUserContent(allocator, options.prompt, options.input);
    defer allocator.free(user_content);

    const messages = [_]Message{
        .{ .role = "system", .content = system_prompt },
        .{ .role = "user", .content = user_content },
    };
    const payload = try std.json.Stringify.valueAlloc(allocator, .{
        .model = options.model,
        .messages = messages,
        .max_tokens = options.max_tokens,
        .stream = false,
    }, .{});
    defer allocator.free(payload);

    const endpoint = try chatCompletionsUrl(allocator, options.base_url);
    defer allocator.free(endpoint);

    const authorization = if (options.api_key) |key|
        try std.fmt.allocPrint(allocator, "Bearer {s}", .{key})
    else
        null;
    defer if (authorization) |value| allocator.free(value);

    var headers_buffer: [3]std.http.Header = undefined;
    var header_count: usize = 0;
    headers_buffer[header_count] = .{ .name = "content-type", .value = "application/json" };
    header_count += 1;
    headers_buffer[header_count] = .{ .name = "accept", .value = "application/json" };
    header_count += 1;
    if (authorization) |value| {
        headers_buffer[header_count] = .{ .name = "authorization", .value = value };
        header_count += 1;
    }

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(endpoint);
    var request = client.request(.POST, uri, .{
        .extra_headers = headers_buffer[0..header_count],
    }) catch |err| return requestFailed(err);
    defer request.deinit();

    request.sendBodyComplete(payload) catch |err| return requestFailed(err);

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = request.receiveHead(&redirect_buffer) catch |err| return requestFailed(err);

    if (response.head.status.class() != .success) {
        return .{ .request_failed = .{ .http_status = @intFromEnum(response.head.status) } };
    }

    var response_buffer: [8 * 1024]u8 = undefined;
    const body = response.reader(&response_buffer).allocRemaining(allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.StreamTooLong => return .{ .response_invalid = .response_too_large },
        error.OutOfMemory => return err,
        else => return requestFailed(err),
    };
    defer allocator.free(body);

    const completion = parseCompletion(allocator, body) catch |err| return .{
        .response_invalid = switch (err) {
            error.EmptyChoices => .empty_choices,
            error.EmptyContent => .missing_output,
            error.AmbiguousOutput => .ambiguous_output,
            else => .malformed_json,
        },
    };
    return .{ .completion = completion };
}

fn requestFailed(err: anyerror) model.CompletionResult {
    return .{ .request_failed = .{ .network = @errorName(err) } };
}

/// Builds the user message while preserving token-saver's instruction/input tags.
fn formatUserContent(allocator: std.mem.Allocator, prompt: []const u8, input: []const u8) ![]u8 {
    if (input.len == 0) return allocator.dupe(u8, prompt);
    return std.fmt.allocPrint(
        allocator,
        "<instructions>{s}</instructions>\n\n<input>{s}</input>",
        .{ prompt, input },
    );
}

/// Appends the standard chat-completions path to a base URL.
fn chatCompletionsUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    return std.fmt.allocPrint(allocator, "{s}/chat/completions", .{trimmed});
}

/// Parses the first assistant choice into an unambiguous caller-owned output.
fn parseCompletion(allocator: std.mem.Allocator, body: []const u8) !model.Completion {
    var parsed = try std.json.parseFromSlice(CompletionResponse, allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) return error.EmptyChoices;
    const choice = parsed.value.choices[0];
    const message = choice.message;
    if (message.content != null and message.refusal != null) return error.AmbiguousOutput;

    var output: model.Output = if (message.content) |content|
        .{ .content = try allocator.dupe(u8, content) }
    else if (message.refusal) |refusal|
        .{ .refusal = try allocator.dupe(u8, refusal) }
    else
        return error.EmptyContent;
    errdefer output.deinit(allocator);

    const finish_reason = if (choice.finish_reason) |value|
        try allocator.dupe(u8, value)
    else
        null;

    const usage: model.Usage = if (parsed.value.usage) |value| .{
        .prompt_tokens = value.prompt_tokens,
        .completion_tokens = value.completion_tokens,
        .total_tokens = value.total_tokens,
    } else .{};

    return .{
        .output = output,
        .finish_reason = finish_reason,
        .usage = usage,
    };
}

test "formatUserContent tags piped input" {
    const content = try formatUserContent(std.testing.allocator, "summarize", "one\ntwo");
    defer std.testing.allocator.free(content);

    try std.testing.expectEqualStrings(
        "<instructions>summarize</instructions>\n\n<input>one\ntwo</input>",
        content,
    );
}

test "parseCompletion ignores unknown response fields" {
    const body =
        \\{"id":"chatcmpl-1","choices":[{"index":0,"message":{"role":"assistant","content":"result"}}]}
    ;
    var completion = try parseCompletion(std.testing.allocator, body);
    defer completion.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("result", completion.output.bytes());
    try std.testing.expectEqualStrings("content", completion.output.kind());
}

test "parseCompletion reports missing choices" {
    try std.testing.expectError(
        error.EmptyChoices,
        parseCompletion(std.testing.allocator, "{\"choices\":[]}"),
    );
}

test "parseCompletion preserves refusal and optional provider facts" {
    const body =
        \\{"choices":[{"message":{"content":null,"refusal":"cannot comply"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"total_tokens":15}}
    ;
    var completion = try parseCompletion(std.testing.allocator, body);
    defer completion.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("refusal", completion.output.kind());
    try std.testing.expectEqualStrings("cannot comply", completion.output.bytes());
    try std.testing.expectEqualStrings("stop", completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 12), completion.usage.prompt_tokens);
    try std.testing.expectEqual(@as(?u64, null), completion.usage.completion_tokens);
    try std.testing.expectEqual(@as(?u64, 15), completion.usage.total_tokens);
}

test "parseCompletion rejects ambiguous output" {
    const body =
        \\{"choices":[{"message":{"content":"answer","refusal":"no"}}]}
    ;
    try std.testing.expectError(
        error.AmbiguousOutput,
        parseCompletion(std.testing.allocator, body),
    );
}

test "parseCompletion rejects malformed JSON and missing output" {
    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        parseCompletion(std.testing.allocator, "{"),
    );
    try std.testing.expectError(
        error.EmptyContent,
        parseCompletion(std.testing.allocator, "{\"choices\":[{\"message\":{}}]}"),
    );
}
