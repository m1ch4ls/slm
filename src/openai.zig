const std = @import("std");

const system_prompt = @embedFile("system.txt");

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

    const Choice = struct {
        message: struct {
            content: ?[]const u8 = null,
            refusal: ?[]const u8 = null,
        },
    };
};

/// Calls an OpenAI-compatible chat completions endpoint and returns owned text.
pub fn complete(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RequestOptions,
) ![]u8 {
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
    var request = try client.request(.POST, uri, .{
        .extra_headers = headers_buffer[0..header_count],
    });
    defer request.deinit();

    try request.sendBodyComplete(payload);

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    var response_buffer: [8 * 1024]u8 = undefined;
    const body = try response.reader(&response_buffer).allocRemaining(allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(body);

    if (response.head.status.class() != .success) {
        std.log.err("API returned {d}: {s}", .{ @intFromEnum(response.head.status), body });
        return error.ApiRequestFailed;
    }

    return parseCompletion(allocator, body);
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

/// Parses the first assistant choice and returns caller-owned content.
fn parseCompletion(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(CompletionResponse, allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) return error.EmptyChoices;
    const message = parsed.value.choices[0].message;
    const content = message.content orelse message.refusal orelse return error.EmptyContent;
    return allocator.dupe(u8, content);
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
    const content = try parseCompletion(std.testing.allocator, body);
    defer std.testing.allocator.free(content);

    try std.testing.expectEqualStrings("result", content);
}

test "parseCompletion reports missing choices" {
    try std.testing.expectError(
        error.EmptyChoices,
        parseCompletion(std.testing.allocator, "{\"choices\":[]}"),
    );
}
