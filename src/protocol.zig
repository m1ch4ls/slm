const std = @import("std");

pub const Request = struct {
    prompt: []const u8,
    stdin: []const u8,
    max_tokens: u32,
};

pub fn writeRequest(file: std.fs.File, request: Request) !void {
    var buf: [4]u8 = undefined;

    std.mem.writeInt(u32, &buf, @intCast(request.prompt.len), .little);
    try file.writeAll(&buf);
    try file.writeAll(request.prompt);

    std.mem.writeInt(u32, &buf, @intCast(request.stdin.len), .little);
    try file.writeAll(&buf);
    try file.writeAll(request.stdin);

    std.mem.writeInt(u32, &buf, request.max_tokens, .little);
    try file.writeAll(&buf);
}

pub fn readRequest(file: std.fs.File, allocator: std.mem.Allocator) !Request {
    var len_buf: [4]u8 = undefined;

    try readExactFile(file, &len_buf);
    const prompt_len = std.mem.readInt(u32, len_buf[0..4], .little);
    if (prompt_len > 1024 * 1024) return error.BufferOverflow;

    const prompt = try readLengthPrefixedFile(file, allocator, prompt_len);

    try readExactFile(file, &len_buf);
    errdefer allocator.free(prompt);
    const stdin_len = std.mem.readInt(u32, len_buf[0..4], .little);
    if (stdin_len > 10 * 1024 * 1024) {
        allocator.free(prompt);
        return error.BufferOverflow;
    }

    const stdin = try readLengthPrefixedFile(file, allocator, stdin_len);
    errdefer allocator.free(stdin);

    try readExactFile(file, &len_buf);
    const max_tokens = std.mem.readInt(u32, len_buf[0..4], .little);

    return Request{
        .prompt = prompt,
        .stdin = stdin,
        .max_tokens = max_tokens,
    };
}

fn readExactFile(file: std.fs.File, buf: []u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try file.read(buf[offset..]);
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

fn readLengthPrefixedFile(file: std.fs.File, allocator: std.mem.Allocator, len: u32) ![]u8 {
    if (len == 0) return try allocator.dupe(u8, "");

    const result = try allocator.alloc(u8, len);

    var remaining: usize = len;
    var offset: usize = 0;
    while (remaining > 0) {
        const n = file.read(result[offset..]) catch |err| {
            allocator.free(result);
            return err;
        };
        if (n == 0) {
            allocator.free(result);
            return error.EndOfStream;
        }
        remaining -= n;
        offset += n;
    }
    return result;
}

pub fn writeToken(file: std.fs.File, token: []const u8) !void {
    if (token.len > 65535) return error.BufferOverflow;

    var len_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &len_buf, @intCast(token.len), .little);
    try file.writeAll(&len_buf);
    try file.writeAll(token);
}

pub fn writeEndMarker(file: std.fs.File) !void {
    var len_buf: [2]u8 = [_]u8{ 0, 0 };
    try file.writeAll(&len_buf);
}

/// Buffered writer for tokens to reduce syscall overhead.
/// Accumulates tokens with length prefixes and flushes in batches.
/// Use flush() periodically (e.g., every 100ms) for fluid streaming.
pub const TokenBuffer = struct {
    buf: [4096]u8,
    len: usize,
    file: std.fs.File,

    pub fn init(file: std.fs.File) TokenBuffer {
        return .{
            .buf = undefined,
            .len = 0,
            .file = file,
        };
    }

    /// Write a token to the buffer. Flushes automatically if needed.
    /// Returns true if the token was written successfully.
    /// Returns false if a flush was needed but failed (caller should stop).
    pub fn writeToken(self: *TokenBuffer, token: []const u8) !bool {
        if (token.len > 65535) return error.BufferOverflow;

        const needed = 2 + token.len;

        // If this single token is larger than the buffer, we need to flush
        // what we have and write this token directly
        if (needed > self.buf.len) {
            try self.flush();
            var len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_buf, @intCast(token.len), .little);
            try self.file.writeAll(&len_buf);
            try self.file.writeAll(token);
            return true;
        }

        // If it won't fit, flush first
        if (self.len + needed > self.buf.len) {
            try self.flush();
        }

        // Write length prefix
        std.mem.writeInt(u16, self.buf[self.len..][0..2], @intCast(token.len), .little);
        self.len += 2;

        // Write token data
        @memcpy(self.buf[self.len..][0..token.len], token);
        self.len += token.len;

        return true;
    }

    /// Flush any buffered data to the file.
    pub fn flush(self: *TokenBuffer) !void {
        if (self.len > 0) {
            try self.file.writeAll(self.buf[0..self.len]);
            self.len = 0;
        }
    }

    /// Write end marker and flush remaining data.
    pub fn writeEndMarker(self: *TokenBuffer) !void {
        // Ensure we have room for end marker (2 bytes)
        if (self.len + 2 > self.buf.len) {
            try self.flush();
        }

        self.buf[self.len] = 0;
        self.buf[self.len + 1] = 0;
        self.len += 2;

        try self.flush();
    }
};

pub fn readToken(file: std.fs.File, allocator: std.mem.Allocator) !?[]const u8 {
    var len_buf: [2]u8 = undefined;
    try readExactFile(file, &len_buf);

    const len = std.mem.readInt(u16, len_buf[0..2], .little);
    if (len == 0) return null;

    return try readLengthPrefixedFile(file, allocator, len);
}

/// Read multiple tokens into a pre-allocated buffer.
/// Returns the total bytes written to output_buffer.
/// output_buffer must be large enough to hold at least one max-size token (65535 bytes).
/// Caller should check if a complete token was read (returned_len >= 2 + token_len).
pub fn readTokensIntoBuffer(file: std.fs.File, output_buffer: []u8) !usize {
    if (output_buffer.len < 2) return error.BufferTooSmall;

    var total_read: usize = 0;
    var buf = output_buffer;

    while (buf.len >= 2) {
        // Try to read the length prefix
        var len_buf: [2]u8 = undefined;
        const len_read = file.read(&len_buf) catch |err| {
            if (total_read == 0) return err;
            break; // Return what we have so far
        };

        if (len_read == 0) {
            if (total_read == 0) return error.EndOfStream;
            break; // EOF, return what we have
        }

        if (len_read != 2) {
            // Partial length read - shouldn't happen with blocking sockets but handle it
            return error.PartialRead;
        }

        const token_len = std.mem.readInt(u16, &len_buf, .little);

        // Check for end marker
        if (token_len == 0) {
            // Write the end marker to buffer as 2 zero bytes
            buf[0] = 0;
            buf[1] = 0;
            total_read += 2;
            break;
        }

        // Check if we have room for this token
        if (buf.len < 2 + token_len) {
            // Not enough room - put back would need unget, instead we just return
            // what we have and let caller handle this on next iteration
            break;
        }

        // Write length to output buffer
        buf[0] = len_buf[0];
        buf[1] = len_buf[1];

        // Read the token data
        var token_offset: usize = 2;
        while (token_offset < 2 + token_len) {
            const n = file.read(buf[token_offset .. 2 + token_len]) catch |err| {
                if (total_read == 0) return err;
                break;
            };
            if (n == 0) {
                if (total_read == 0) return error.EndOfStream;
                break;
            }
            token_offset += n;
        }

        const bytes_this_token = 2 + token_len;
        total_read += bytes_this_token;
        buf = buf[bytes_this_token..];
    }

    return total_read;
}

/// Parse tokens from a buffer and write them to a writer.
/// Returns true if an end marker (0-length token) was found.
pub fn writeTokensFromBuffer(buffer: []const u8, writer: anytype) !bool {
    var offset: usize = 0;

    while (offset + 2 <= buffer.len) {
        const token_len = std.mem.readInt(u16, buffer[offset..][0..2], .little);

        if (token_len == 0) {
            return true; // End marker found
        }

        if (offset + 2 + token_len > buffer.len) {
            // Incomplete token at end of buffer
            break;
        }

        try writer.writeAll(buffer[offset + 2 .. offset + 2 + token_len]);
        offset += 2 + token_len;
    }

    return false;
}

test "writeRequest and readRequest roundtrip" {
    const file = try std.fs.createFileAbsolute("/tmp/protocol_test", .{});
    defer file.close();

    const request = Request{
        .prompt = "test prompt",
        .stdin = "stdin content",
        .max_tokens = 512,
    };

    try writeRequest(file, request);
    try file.seekTo(0);

    var new_file = try std.fs.openFileAbsolute("/tmp/protocol_test", .{});
    defer new_file.close();

    const read_req = try readRequest(new_file, std.testing.allocator);
    defer {
        std.testing.allocator.free(read_req.prompt);
        std.testing.allocator.free(read_req.stdin);
    }

    try std.testing.expectEqualStrings("test prompt", read_req.prompt);
    try std.testing.expectEqualStrings("stdin content", read_req.stdin);
    try std.testing.expectEqual(@as(u32, 512), read_req.max_tokens);
}

test "writeRequest with empty fields" {
    var temp_file = try std.fs.createFileAbsolute("/tmp/protocol_empty_test", .{});
    defer std.fs.cwd().deleteFile("/tmp/protocol_empty_test") catch {};

    const request = Request{
        .prompt = "",
        .stdin = "",
        .max_tokens = 100,
    };

    try writeRequest(temp_file, request);
    try temp_file.seekTo(0);

    var new_file = try std.fs.openFileAbsolute("/tmp/protocol_empty_test", .{});
    defer new_file.close();

    const read_req = try readRequest(new_file, std.testing.allocator);
    defer {
        std.testing.allocator.free(read_req.prompt);
        std.testing.allocator.free(read_req.stdin);
    }

    try std.testing.expectEqualStrings("", read_req.prompt);
    try std.testing.expectEqualStrings("", read_req.stdin);
    try std.testing.expectEqual(@as(u32, 100), read_req.max_tokens);
}

test "writeToken and readToken roundtrip" {
    var temp_file = try std.fs.createFileAbsolute("/tmp/token_test", .{});
    defer std.fs.cwd().deleteFile("/tmp/token_test") catch {};

    try writeToken(temp_file, "Hello");
    try writeToken(temp_file, "World");
    try writeEndMarker(temp_file);
    try temp_file.seekTo(0);

    var new_file = try std.fs.openFileAbsolute("/tmp/token_test", .{});
    defer new_file.close();

    const tok1 = (try readToken(new_file, std.testing.allocator)).?;
    defer std.testing.allocator.free(tok1);
    try std.testing.expectEqualStrings("Hello", tok1);

    const tok2 = (try readToken(new_file, std.testing.allocator)).?;
    defer std.testing.allocator.free(tok2);
    try std.testing.expectEqualStrings("World", tok2);

    const tok3 = try readToken(new_file, std.testing.allocator);
    try std.testing.expect(tok3 == null);
}

test "writeToken with special characters" {
    var temp_file = try std.fs.createFileAbsolute("/tmp/token_special_test", .{});
    defer std.fs.cwd().deleteFile("/tmp/token_special_test") catch {};

    try writeToken(temp_file, "line1\nline2\ttab");
    try writeToken(temp_file, "emoji 🎉");
    try writeEndMarker(temp_file);
    try temp_file.seekTo(0);

    var new_file = try std.fs.openFileAbsolute("/tmp/token_special_test", .{});
    defer new_file.close();

    const tok1 = (try readToken(new_file, std.testing.allocator)).?;
    defer std.testing.allocator.free(tok1);
    try std.testing.expectEqualStrings("line1\nline2\ttab", tok1);

    const tok2 = (try readToken(new_file, std.testing.allocator)).?;
    defer std.testing.allocator.free(tok2);
    try std.testing.expectEqualStrings("emoji 🎉", tok2);
}

test "BufferOverflow protection" {
    var temp_file = try std.fs.createFileAbsolute("/tmp/overflow_test", .{});
    defer std.fs.cwd().deleteFile("/tmp/overflow_test") catch {};

    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, 1024 * 1024 + 1, .little);
    try temp_file.writeAll(&buf);

    try temp_file.seekTo(0);
    var new_file = try std.fs.openFileAbsolute("/tmp/overflow_test", .{});
    defer new_file.close();

    const result = readRequest(new_file, std.testing.allocator);
    try std.testing.expectError(error.BufferOverflow, result);
}
