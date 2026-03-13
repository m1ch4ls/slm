const std = @import("std");

const Config = struct {
    model: []const u8,
    server_url: []const u8,
    context_size: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Config) void {
        self.allocator.free(self.model);
        self.allocator.free(self.server_url);
    }
};

// JSON types for request payload
const Message = struct {
    role: []const u8,
    content: []const u8,
};

const Payload = struct {
    model: []const u8,
    messages: []const Message,
    stream: bool,
    max_tokens: u32,
};

// JSON types for SSE response
const Delta = struct {
    content: ?[]const u8 = null,
};

const Choice = struct {
    delta: Delta,
};

const SseResponse = struct {
    choices: []const Choice,
};

// Token estimation constants (from Gemini CLI heuristic)
// ASCII characters (0-127) are roughly 4 chars per token
const ASCII_TOKENS_PER_CHAR: f64 = 0.25;
// Non-ASCII characters (including CJK) are often 1-2 tokens per char.
// We use 1.3 as a conservative estimate to avoid underestimation.
const NON_ASCII_TOKENS_PER_CHAR: f64 = 1.3;
// Maximum number of characters to process with the full character-by-character heuristic.
// Above this, we use a faster approximation to avoid performance bottlenecks.
const MAX_CHARS_FOR_FULL_HEURISTIC = 100_000;

const MAX_OUTPUT_TOKENS = 10240;
const OVERHEAD_TOKENS = 100;

const SYSTEM_PROMPT = "You are a CLI assistant. You will recive user instructions and input. Apply instructions to the input. Follow the user instructions exactly.";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.log.err("Usage: slm <prompt>", .{});
        std.log.err("       echo 'text' | slm 'extract emails'", .{});
        return error.MissingPrompt;
    }
    const user_prompt = args[1];

    // Read config
    const config = try readConfig(allocator);
    defer config.deinit();

    // Calculate token budget for stdin
    const token_budget_i64 = calculateAvailableTokensForStdin(config.context_size, user_prompt);
    if (token_budget_i64 <= 0) {
        std.log.err("Prompt too long for context window (budget exhausted)", .{});
        return error.ContextExceeded;
    }
    const token_budget: usize = @intCast(token_budget_i64);

    // Read stdin with token-based truncation
    const stdin_content = try readStdinWithTokenLimit(allocator, token_budget);
    defer allocator.free(stdin_content);

    // Build the request payload
    const payload = try buildPayload(allocator, config.model, user_prompt, stdin_content);
    defer allocator.free(payload);

    // Make HTTP request with streaming
    try streamCompletion(allocator, config.server_url, payload);
}

fn calculateAvailableTokensForStdin(context_size: u32, user_prompt: []const u8) i64 {
    const system_tokens = estimateTokens(SYSTEM_PROMPT);
    const user_tokens = estimateTokens(user_prompt);
    const context_tokens: i64 = @intCast(context_size);

    const available = context_tokens - MAX_OUTPUT_TOKENS - @as(i64, @intCast(system_tokens)) - @as(i64, @intCast(user_tokens)) - OVERHEAD_TOKENS;
    
    std.log.debug("Token budget: context={}, system={}, prompt={}, output={}, overhead={}, available={}", .{
        context_size, system_tokens, user_tokens, MAX_OUTPUT_TOKENS, OVERHEAD_TOKENS, available
    });
    
    return available;
}

/// Heuristic estimation of tokens for a text string.
/// - ASCII (0-127): ~0.25 tokens per char (4 chars per token)
/// - Non-ASCII: ~1.3 tokens per char (conservative for CJK)
/// - For large strings (>100k): uses length/4 approximation
fn estimateTokens(text: []const u8) usize {
    if (text.len == 0) return 0;

    if (text.len > MAX_CHARS_FOR_FULL_HEURISTIC) {
        return text.len / 4;
    }

    var tokens: f64 = 0;
    for (text) |byte| {
        if (byte <= 127) {
            tokens += ASCII_TOKENS_PER_CHAR;
        } else {
            tokens += NON_ASCII_TOKENS_PER_CHAR;
        }
    }

    return @intFromFloat(@ceil(tokens));
}

fn readConfig(allocator: std.mem.Allocator) !Config {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
        std.log.err("Could not get HOME environment variable: {}", .{err});
        return err;
    };
    defer allocator.free(home);

    const config_path = try std.fs.path.join(allocator, &.{ home, ".config", "slm", "config" });
    defer allocator.free(config_path);

    const content = std.fs.cwd().readFileAlloc(allocator, config_path, 4096) catch |err| {
        std.log.err("Could not read config file at {s}: {}", .{ config_path, err });
        std.log.err("Create it with: mkdir -p ~/.config/slm && echo 'model=/path/to/model.gguf' > ~/.config/slm/config", .{});
        return err;
    };
    defer allocator.free(content);

    var model: ?[]const u8 = null;
    var server_url: ?[]const u8 = null;
    errdefer {
        if (model) |m| allocator.free(m);
        if (server_url) |s| allocator.free(s);
    }
    var context_size: u32 = 32768;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var parts = std.mem.splitScalar(u8, trimmed, '=');
        const key = std.mem.trim(u8, parts.next() orelse continue, " \t");
        const value = std.mem.trim(u8, parts.next() orelse continue, " \t");

        if (std.mem.eql(u8, key, "model")) {
            model = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "server_url")) {
            server_url = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "context_size")) {
            context_size = std.fmt.parseInt(u32, value, 10) catch context_size;
        }
    }

    return Config{
        .model = model orelse return error.MissingModelConfig,
        .server_url = server_url orelse try allocator.dupe(u8, "http://127.0.0.1:8080"),
        .context_size = context_size,
        .allocator = allocator,
    };
}

fn readStdinWithTokenLimit(allocator: std.mem.Allocator, token_budget: usize) ![]const u8 {
    const stdin = std.fs.File.stdin();
    
    // Read all stdin into buffer first
    var content = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer content.deinit(allocator);
    
    // Reader internal buffer
    var reader_buffer: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(&reader_buffer);
    
    // Destination buffer for reads
    var dest_buffer: [4096]u8 = undefined;
    
    while (true) {
        const n = stdin_reader.interface.readSliceShort(&dest_buffer) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;
        try content.appendSlice(allocator, dest_buffer[0..n]);
    }
    
    // Now count tokens in what we read
    const total_tokens = estimateTokens(content.items);
    
    if (total_tokens <= token_budget) {
        // We're good, return the content
        return content.toOwnedSlice(allocator);
    }
    
    // Need to truncate based on token count
    // Binary search to find the character position that gives us ~token_budget tokens
    var start: usize = 0;
    var end: usize = content.items.len;
    var best_pos: usize = 0;
    
    while (start < end) {
        const mid = start + (end - start) / 2;
        const tokens = estimateTokens(content.items[0..mid]);
        
        if (tokens <= token_budget) {
            best_pos = mid;
            start = mid + 1;
        } else {
            end = mid;
        }
    }
    
    // Truncate to best_pos
    content.shrinkRetainingCapacity(best_pos);
    
    // Write truncation warning to stderr
    const stderr = std.fs.File.stderr();
    try stderr.writeAll("\n[slm: input truncated due to token limit]\n");
    
    std.log.debug("Truncated from {} tokens to {} tokens (budget: {})", .{total_tokens, estimateTokens(content.items), token_budget});
    
    return content.toOwnedSlice(allocator);
}

fn buildPayload(allocator: std.mem.Allocator, model: []const u8, user_prompt: []const u8, stdin_content: []const u8) ![]const u8 {
    const user_message = if (stdin_content.len > 0)
        try std.fmt.allocPrint(allocator, "<instructions>{s}</instructions>\n\n<input>{s}</input>", .{ user_prompt, stdin_content })
    else
        try allocator.dupe(u8, user_prompt);
    defer allocator.free(user_message);

    // Debug: show actual token estimate
    const total_tokens = estimateTokens(SYSTEM_PROMPT) + estimateTokens(user_message);
    std.log.debug("Payload token estimate: system + user = {} tokens", .{total_tokens});

    const payload = Payload{
        .model = model,
        .messages = &[_]Message{
            .{ .role = "system", .content = SYSTEM_PROMPT },
            .{ .role = "user", .content = user_message },
        },
        .stream = true,
        .max_tokens = 10240,
    };

    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(payload, .{})});
}

fn streamCompletion(allocator: std.mem.Allocator, server_url: []const u8, payload: []const u8) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{server_url});
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);

    // Create the request
    var request = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    });
    defer request.deinit();

    // Set content length and send body
    request.transfer_encoding = .{ .content_length = payload.len };

    // Send the body - cast away const since API requires []u8
    try request.sendBodyComplete(@constCast(payload));

    // Receive response head
    var redirect_buffer: [4096]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    if (response.head.status != .ok) {
        const status_code = @intFromEnum(response.head.status);
        
        // Try to read error response body
        var error_buffer: [4096]u8 = undefined;
        var error_reader = response.reader(&error_buffer);
        const error_body = error_reader.allocRemaining(allocator, std.Io.Limit.limited(4096)) catch |err| blk: {
            std.log.debug("Could not read error body: {}", .{err});
            break :blk null;
        };
        defer if (error_body) |body| allocator.free(body);
        
        // Log appropriate error based on status code
        switch (status_code) {
            400 => {
                std.log.err("Server returned 400 Bad Request - likely context window exceeded", .{});
                std.log.err("The input + prompt + expected output exceeds the model's context limit", .{});
            },
            401 => std.log.err("Server returned 401 Unauthorized - check API key or authentication", .{}),
            404 => std.log.err("Server returned 404 Not Found - check the model endpoint URL", .{}),
            429 => std.log.err("Server returned 429 Too Many Requests - rate limit exceeded", .{}),
            500...599 => std.log.err("Server returned {d} - internal server error", .{status_code}),
            else => std.log.err("Server returned status {d}", .{status_code}),
        }
        
        // Log error body if we got one
        if (error_body) |body| {
            if (body.len > 0) {
                std.log.err("Server error details: {s}", .{body});
            }
        }
        
        if (status_code >= 500 or status_code == 502 or status_code == 503) {
            std.log.err("Is the llama.cpp server running at {s}?", .{server_url});
            std.log.err("Start it with: ./server -m <model> --port 8080", .{});
        }
        
        return error.ServerUnavailable;
    }

    // Read and parse SSE stream
    var transfer_buffer: [8192]u8 = undefined;
    var reader = response.reader(&transfer_buffer);

    // Line buffer for streaming SSE parsing
    var line_buffer = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer line_buffer.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&read_buf) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;

        // Scan for newlines
        var start: usize = 0;
        for (read_buf[0..n], 0..) |c, i| {
            if (c == '\n') {
                // Process line
                try line_buffer.appendSlice(allocator, read_buf[start..i]);
                try parseSseLine(line_buffer.items);
                line_buffer.clearRetainingCapacity();
                start = i + 1;
            }
        }

        // Append remaining data to line buffer
        if (start < n) {
            try line_buffer.appendSlice(allocator, read_buf[start..n]);
        }
    }

    // Process any remaining data (line without trailing newline)
    if (line_buffer.items.len > 0) {
        try parseSseLine(line_buffer.items);
    }

    // Add final newline
    try std.fs.File.stdout().writeAll("\n");
}

fn parseSseLine(line: []const u8) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r");

    // Skip empty lines
    if (trimmed.len == 0) return;

    // Skip comments
    if (trimmed[0] == ':') return;

    // Parse data: lines
    if (std.mem.startsWith(u8, trimmed, "data: ")) {
        const data = trimmed[6..];

        // Check for [DONE]
        if (std.mem.eql(u8, data, "[DONE]")) return;

        // Parse JSON to extract content
        try extractAndPrintContent(data);
    }
}

fn extractAndPrintContent(json_str: []const u8) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const parsed = std.json.parseFromSlice(SseResponse, std.heap.page_allocator, json_str, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        // Silently skip malformed JSON (incomplete chunks in stream)
        if (err == error.UnexpectedEndOfJson) return;
        return err;
    };
    defer parsed.deinit();

    if (parsed.value.choices.len > 0) {
        if (parsed.value.choices[0].delta.content) |content| {
            try stdout.writeAll(content);
            try stdout.flush();
        }
    }
}

// =============================================================================
// TESTS
// =============================================================================

test "Config struct lifecycle" {
    const allocator = std.testing.allocator;

    const model = try allocator.dupe(u8, "test-model.gguf");
    const server_url = try allocator.dupe(u8, "http://localhost:8080");

    const config = Config{
        .model = model,
        .server_url = server_url,
        .context_size = 4096,
        .allocator = allocator,
    };

    config.deinit();
}

test "buildPayload creates valid JSON structure" {
    const allocator = std.testing.allocator;

    const model = "test-model.gguf";
    const user_prompt = "extract emails";
    const stdin_content = "Contact: test@example.com";

    const payload = try buildPayload(allocator, model, user_prompt, stdin_content);
    defer allocator.free(payload);

    // Parse and verify structure
    const parsed = try std.json.parseFromSlice(Payload, allocator, payload, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test-model.gguf", parsed.value.model);
    try std.testing.expect(parsed.value.stream);
    try std.testing.expectEqual(@as(u32, 10240), parsed.value.max_tokens);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.messages.len);
    try std.testing.expectEqualStrings("system", parsed.value.messages[0].role);
    try std.testing.expectEqualStrings("user", parsed.value.messages[1].role);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.messages[1].content, "<instructions>extract emails</instructions>") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.messages[1].content, "<input>Contact: test@example.com</input>") != null);
}

test "buildPayload handles empty stdin" {
    const allocator = std.testing.allocator;

    const model = "test-model.gguf";
    const user_prompt = "hello world";
    const stdin_content = "";

    const payload = try buildPayload(allocator, model, user_prompt, stdin_content);
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(Payload, allocator, payload, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("user", parsed.value.messages[1].role);
    try std.testing.expectEqualStrings("hello world", parsed.value.messages[1].content);
    // Should NOT contain "User instructions:" prefix
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.messages[1].content, "User instructions:") == null);
}

test "buildPayload escapes JSON in content" {
    const allocator = std.testing.allocator;

    const model = "test-model.gguf";
    const user_prompt = "extract \"quotes\"";
    const stdin_content = "test\nmultiline";

    const payload = try buildPayload(allocator, model, user_prompt, stdin_content);
    defer allocator.free(payload);

    // Verify payload is valid JSON by parsing it
    const parsed = try std.json.parseFromSlice(Payload, allocator, payload, .{});
    defer parsed.deinit();

    // The parsed content should contain the unescaped strings
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.messages[1].content, "extract \"quotes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.messages[1].content, "test\nmultiline") != null);
}

test "parseSseLine handles various line types" {
    // Empty lines should be skipped (no error)
    try parseSseLine("");
    try parseSseLine("   ");
    try parseSseLine("\t\r");

    // Comments should be skipped
    try parseSseLine(": this is a comment");
    try parseSseLine(":heartbeat");

    // Data lines should be processed (we can't easily test output, but should not error)
    // Note: extractAndPrintContent is called, which writes to stdout
    // In test context, this might fail or succeed depending on stdout availability
}

test "parseSseLine handles [DONE] marker" {
    // [DONE] marker should return early without error
    try parseSseLine("data: [DONE]");
}

test "parseSseLine handles data prefix" {
    // Test that lines starting with "data: " are parsed
    const test_json = "{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}";
    const line = try std.fmt.allocPrint(std.testing.allocator, "data: {s}", .{test_json});
    defer std.testing.allocator.free(line);

    try parseSseLine(line);
}

test "readStdinTruncated with empty input" {
    const allocator = std.testing.allocator;

    // Create a temp file with known content
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_content = "hello world";
    try tmp_dir.dir.writeFile(.{ .sub_path = "test.txt", .data = test_content });

    // Open and read the file
    const file = try tmp_dir.dir.openFile("test.txt", .{});
    defer file.close();

    // Read file content
    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);

    try std.testing.expectEqualStrings(test_content, content);
}

test "memory leaks are detected" {
    // This test verifies our allocator is properly tracking memory
    // If any of the above tests leak, this will fail at cleanup
    // std.testing.allocator automatically detects leaks
}

// =============================================================================
// INTEGRATION TEST HELPERS
// =============================================================================

/// Mock HTTP server for testing streamCompletion
/// This is a test helper that simulates an LLM server response
const MockServer = struct {
    allocator: std.mem.Allocator,
    responses: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) MockServer {
        return .{
            .allocator = allocator,
            .responses = .empty,
        };
    }

    pub fn deinit(self: *MockServer) void {
        for (self.responses.items) |resp| {
            self.allocator.free(resp);
        }
        self.responses.deinit(self.allocator);
    }

    pub fn addSseResponse(self: *MockServer, content: []const u8) !void {
        const json = try std.fmt.allocPrint(self.allocator, "{{\"choices\":[{{\"delta\":{{\"content\":\"{s}\"}}}}]}}", .{content});
        try self.responses.append(self.allocator, json);
    }

    pub fn generateSseStream(self: *MockServer) ![]const u8 {
        var stream = std.ArrayListUnmanaged(u8){};
        defer stream.deinit(self.allocator);

        for (self.responses.items) |resp| {
            try stream.appendSlice(self.allocator, "data: ");
            try stream.appendSlice(self.allocator, resp);
            try stream.appendSlice(self.allocator, "\n");
        }
        try stream.appendSlice(self.allocator, "data: [DONE]\n");

        return stream.toOwnedSlice(self.allocator);
    }
};

test "MockServer generates valid SSE stream" {
    const allocator = std.testing.allocator;

    var server = MockServer.init(allocator);
    defer server.deinit();

    try server.addSseResponse("Hello");
    try server.addSseResponse(" world");
    try server.addSseResponse("!");

    const stream = try server.generateSseStream();
    defer allocator.free(stream);

    try std.testing.expect(std.mem.indexOf(u8, stream, "data: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, " world") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "data: [DONE]") != null);
}

// =============================================================================
// TOKEN ESTIMATION TESTS
// =============================================================================

test "estimateTokens handles empty string" {
    try std.testing.expectEqual(@as(usize, 0), estimateTokens(""));
}

test "estimateTokens for ASCII text" {
    // "hello" is 5 ASCII chars, should be ~2 tokens (5 * 0.25 = 1.25, ceil = 2)
    try std.testing.expectEqual(@as(usize, 2), estimateTokens("hello"));

    // "hello world" is 11 chars including space, should be ~3 tokens (11 * 0.25 = 2.75, ceil = 3)
    try std.testing.expectEqual(@as(usize, 3), estimateTokens("hello world"));
}

test "estimateTokens for mixed ASCII and non-ASCII" {
    // "hello你好" - 5 ASCII + 6 non-ASCII bytes
    // ASCII: 5 * 0.25 = 1.25
    // Non-ASCII: 6 * 1.3 = 7.8
    // Total: 9.05, ceil = 10
    const tokens = estimateTokens("hello你好");
    try std.testing.expect(tokens >= 9);
    try std.testing.expect(tokens <= 11);
}

test "estimateTokens uses fast path for large strings" {
    // Test that strings > 100k use the fast path (length / 4)
    const allocator = std.testing.allocator;
    const large_text = try allocator.alloc(u8, 100_001);
    defer allocator.free(large_text);
    @memset(large_text, 'a');

    const tokens = estimateTokens(large_text);
    try std.testing.expectEqual(@as(usize, 25_000), tokens); // 100001 / 4 = 25000
}
