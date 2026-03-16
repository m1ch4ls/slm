const std = @import("std");

const log = std.log.scoped(.think_filter);

pub const ThinkFilter = struct {
    buffer: std.ArrayList(u8),
    in_think: bool,
    strip_leading_ws: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ThinkFilter {
        return .{
            .buffer = try std.ArrayList(u8).initCapacity(allocator, 256),
            .in_think = false,
            .strip_leading_ws = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ThinkFilter) void {
        self.buffer.deinit(self.allocator);
    }

    /// Process text and return slices of output to emit.
    /// Caller owns the returned slices (must free with allocator).
    pub fn process(self: *ThinkFilter, allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
        var chunks = try std.ArrayList([]const u8).initCapacity(allocator, 8);
        errdefer {
            for (chunks.items) |chunk| {
                allocator.free(chunk);
            }
            chunks.deinit(allocator);
        }

        // Append new text to buffer
        try self.buffer.appendSlice(self.allocator, text);

        var emit_start: usize = 0;
        var i: usize = 0;

        while (i < self.buffer.items.len) {
            if (!self.in_think) {
                // Look for <think> opening tag
                if (i + 7 <= self.buffer.items.len and std.mem.eql(u8, self.buffer.items[i .. i + 7], "<think>")) {
                    // Emit content before the think tag
                    if (emit_start < i) {
                        const chunk = try allocator.dupe(u8, self.buffer.items[emit_start..i]);
                        try chunks.append(allocator, chunk);
                    }
                    self.in_think = true;
                    i += 7;
                    emit_start = i;
                } else {
                    i += 1;
                }
            } else {
                // Inside think block, look for </think> closing tag
                if (i + 8 <= self.buffer.items.len and std.mem.eql(u8, self.buffer.items[i .. i + 8], "</think>")) {
                    log.debug("Found </think> at i={}", .{i});
                    self.in_think = false;
                    self.strip_leading_ws = true;
                    i += 8;
                    emit_start = i;
                } else {
                    i += 1;
                }
            }
        }

        // Emit safe content at the end (outside think blocks only)
        if (!self.in_think and emit_start < self.buffer.items.len) {
            // Strip leading whitespace after think block
            if (self.strip_leading_ws) {
                while (emit_start < self.buffer.items.len and
                    (self.buffer.items[emit_start] == '\n' or self.buffer.items[emit_start] == '\r' or
                        self.buffer.items[emit_start] == ' ' or self.buffer.items[emit_start] == '\t'))
                {
                    emit_start += 1;
                }
                if (emit_start < self.buffer.items.len) {
                    self.strip_leading_ws = false;
                }
            }

            // Hold back any suffix that could be a prefix of "<think>" or "</think>"
            const safe_end = partialTagSafeEnd(self.buffer.items, emit_start);

            if (emit_start < safe_end) {
                const chunk = try allocator.dupe(u8, self.buffer.items[emit_start..safe_end]);
                try chunks.append(allocator, chunk);
                emit_start = safe_end;
            }
        }

        // Keep unprocessed content in buffer
        const remaining = self.buffer.items.len - emit_start;
        if (remaining > 0 and emit_start > 0) {
            std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[emit_start..]);
        }
        self.buffer.shrinkRetainingCapacity(remaining);

        return try chunks.toOwnedSlice(allocator);
    }

    const open_tag = "<think>";
    const close_tag = "</think>";

    /// Find the safe emission boundary in buffer[emit_start..].
    /// Returns the index up to which we can safely emit, holding back
    /// any trailing suffix that could be a prefix of "<think>" or "</think>".
    fn partialTagSafeEnd(buf: []const u8, emit_start: usize) usize {
        const tail = buf[emit_start..];
        // Check suffixes of decreasing length: could the last N bytes
        // be the start of a tag we haven't fully received yet?
        // Max prefix to check is max(open_tag.len, close_tag.len) - 1 = 7
        const max_prefix = @max(open_tag.len, close_tag.len) - 1;
        const check_len: usize = @min(tail.len, max_prefix);

        var hold_back: usize = 0;
        for (1..check_len + 1) |suffix_len| {
            const suffix = tail[tail.len - suffix_len ..];
            if (isTagPrefix(suffix, open_tag) or isTagPrefix(suffix, close_tag)) {
                hold_back = suffix_len;
            }
        }
        return buf.len - hold_back;
    }

    /// Check if `candidate` is a prefix of `tag`
    fn isTagPrefix(candidate: []const u8, tag: []const u8) bool {
        if (candidate.len > tag.len) return false;
        return std.mem.eql(u8, candidate, tag[0..candidate.len]);
    }

    /// Flush any remaining content. Call at end of stream.
    /// Caller owns the returned slice (must free with allocator).
    pub fn flush(self: *ThinkFilter, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.in_think) {
            // Still in think block, discard everything
            self.buffer.clearRetainingCapacity();
            self.in_think = false;
            return null;
        }

        if (self.buffer.items.len > 0) {
            const result = try allocator.dupe(u8, self.buffer.items);
            self.buffer.clearRetainingCapacity();
            return result;
        }

        return null;
    }
};

test "filters think blocks" {
    const allocator = std.testing.allocator;
    var filter = try ThinkFilter.init(allocator);
    defer filter.deinit();

    const chunks = try filter.process(allocator, "Hello <think>this is hidden</think> World");
    defer {
        for (chunks) |chunk| allocator.free(chunk);
        allocator.free(chunks);
    }

    var result = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer result.deinit(allocator);
    for (chunks) |chunk| {
        try result.appendSlice(allocator, chunk);
    }
    try std.testing.expectEqualStrings("Hello World", result.items);
}

test "handles no think tags" {
    const allocator = std.testing.allocator;
    var filter = try ThinkFilter.init(allocator);
    defer filter.deinit();

    const chunks = try filter.process(allocator, "Just regular text");
    defer {
        for (chunks) |chunk| allocator.free(chunk);
        allocator.free(chunks);
    }

    try std.testing.expectEqualStrings("Just regular text", chunks[0]);
}

test "handles multiple think blocks" {
    const allocator = std.testing.allocator;
    var filter = try ThinkFilter.init(allocator);
    defer filter.deinit();

    const chunks = try filter.process(allocator, "A<think>1</think>B<think>2</think>C");
    defer {
        for (chunks) |chunk| allocator.free(chunk);
        allocator.free(chunks);
    }

    var result = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer result.deinit(allocator);
    for (chunks) |chunk| {
        try result.appendSlice(allocator, chunk);
    }
    try std.testing.expectEqualStrings("ABC", result.items);
}

test "handles empty think block" {
    const allocator = std.testing.allocator;
    var filter = try ThinkFilter.init(allocator);
    defer filter.deinit();

    const chunks = try filter.process(allocator, "Before<think></think>After");
    defer {
        for (chunks) |chunk| allocator.free(chunk);
        allocator.free(chunks);
    }

    var result = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer result.deinit(allocator);
    for (chunks) |chunk| {
        try result.appendSlice(allocator, chunk);
    }
    try std.testing.expectEqualStrings("BeforeAfter", result.items);
}

test "handles complete tags only" {
    const allocator = std.testing.allocator;
    var filter = try ThinkFilter.init(allocator);
    defer filter.deinit();

    // Space is not a tag prefix, so "Before " is emitted fully
    const chunks1 = try filter.process(allocator, "Before ");
    defer {
        for (chunks1) |chunk| allocator.free(chunk);
        allocator.free(chunks1);
    }

    const chunks2 = try filter.process(allocator, "<think>hidden</think> After");
    defer {
        for (chunks2) |chunk| allocator.free(chunk);
        allocator.free(chunks2);
    }

    try std.testing.expectEqualStrings("Before ", chunks1[0]);
}

test "handles incomplete closing tag" {
    const allocator = std.testing.allocator;
    var filter = try ThinkFilter.init(allocator);
    defer filter.deinit();

    const chunks1 = try filter.process(allocator, "<think>content</thi");
    defer {
        for (chunks1) |chunk| allocator.free(chunk);
        allocator.free(chunks1);
    }

    const chunks2 = try filter.process(allocator, "nk>visible");
    defer {
        for (chunks2) |chunk| allocator.free(chunk);
        allocator.free(chunks2);
    }

    // First call: inside think, nothing emitted
    try std.testing.expectEqual(0, chunks1.len);

    // Second call: closing tag completes, emit "visible"
    try std.testing.expectEqualStrings("visible", chunks2[0]);
}

test "flush returns remaining content" {
    const allocator = std.testing.allocator;
    var filter = try ThinkFilter.init(allocator);
    defer filter.deinit();

    // Space is not a tag prefix, so "Hello " is emitted fully
    const chunks = try filter.process(allocator, "Hello ");
    defer {
        for (chunks) |chunk| allocator.free(chunk);
        allocator.free(chunks);
    }

    try std.testing.expectEqualStrings("Hello ", chunks[0]);

    // Nothing remaining to flush
    const remaining = try filter.flush(allocator);
    defer if (remaining) |r| allocator.free(r);
    try std.testing.expectEqual(null, remaining);
}

test "holds back partial opening tag" {
    const allocator = std.testing.allocator;
    var filter = try ThinkFilter.init(allocator);
    defer filter.deinit();

    // "<thi" is a prefix of "<think>", so it gets held back
    const chunks1 = try filter.process(allocator, "Hello <thi");
    defer {
        for (chunks1) |chunk| allocator.free(chunk);
        allocator.free(chunks1);
    }

    var result1 = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer result1.deinit(allocator);
    for (chunks1) |chunk| {
        try result1.appendSlice(allocator, chunk);
    }
    try std.testing.expectEqualStrings("Hello ", result1.items);

    // Complete the tag, content inside is suppressed, "World" emitted
    const chunks2 = try filter.process(allocator, "nk>secret</think>World");
    defer {
        for (chunks2) |chunk| allocator.free(chunk);
        allocator.free(chunks2);
    }

    var result2 = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer result2.deinit(allocator);
    for (chunks2) |chunk| {
        try result2.appendSlice(allocator, chunk);
    }
    try std.testing.expectEqualStrings("World", result2.items);
}

test "holds back partial closing tag" {
    const allocator = std.testing.allocator;
    var filter = try ThinkFilter.init(allocator);
    defer filter.deinit();

    // "</thi" is a prefix of "</think>", held back while in_think
    const chunks1 = try filter.process(allocator, "<think>secret</thi");
    defer {
        for (chunks1) |chunk| allocator.free(chunk);
        allocator.free(chunks1);
    }
    try std.testing.expectEqual(@as(usize, 0), chunks1.len);

    const chunks2 = try filter.process(allocator, "nk>visible");
    defer {
        for (chunks2) |chunk| allocator.free(chunk);
        allocator.free(chunks2);
    }
    try std.testing.expectEqualStrings("visible", chunks2[0]);
}

test "lone < at end is held back" {
    const allocator = std.testing.allocator;
    var filter = try ThinkFilter.init(allocator);
    defer filter.deinit();

    const chunks = try filter.process(allocator, "Hello<");
    defer {
        for (chunks) |chunk| allocator.free(chunk);
        allocator.free(chunks);
    }

    var result = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer result.deinit(allocator);
    for (chunks) |chunk| {
        try result.appendSlice(allocator, chunk);
    }
    try std.testing.expectEqualStrings("Hello", result.items);

    // Turns out it wasn't a think tag — flush emits the held-back "<"
    const remaining = try filter.flush(allocator);
    defer if (remaining) |r| allocator.free(r);
    try std.testing.expectEqualStrings("<", remaining.?);
}

test "flush discards unclosed think block" {
    const allocator = std.testing.allocator;
    var filter = try ThinkFilter.init(allocator);
    defer filter.deinit();

    const chunks = try filter.process(allocator, "<think>unclosed");
    defer {
        for (chunks) |chunk| allocator.free(chunk);
        allocator.free(chunks);
    }

    const remaining = try filter.flush(allocator);
    try std.testing.expectEqual(null, remaining);
}

test "token-by-token streaming with think block" {
    const allocator = std.testing.allocator;
    var filter = try ThinkFilter.init(allocator);
    defer filter.deinit();

    var all_output = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer all_output.deinit(allocator);

    // Simulate exact daemon token stream: <think>\n\n</think>\n\nHello! How can I help you today?
    const tokens = &[_][]const u8{ "<think>", "\n", "\n", "</think>", "\n", "\n", "Hello", "!", " How", " can", " I", " help", " you", " today", "?" };

    for (tokens) |token| {
        const chunks = try filter.process(allocator, token);
        defer {
            for (chunks) |c| allocator.free(c);
            allocator.free(chunks);
        }
        for (chunks) |c| {
            try all_output.appendSlice(allocator, c);
        }
    }

    // Flush remaining
    if (try filter.flush(allocator)) |remaining| {
        defer allocator.free(remaining);
        try all_output.appendSlice(allocator, remaining);
    }

    try std.testing.expectEqualStrings("Hello! How can I help you today?", all_output.items);
}

test "long text after think block does not overflow" {
    const allocator = std.testing.allocator;
    var filter = try ThinkFilter.init(allocator);
    defer filter.deinit();

    // Simulate streaming: <think> token, content, </think> token, then long text
    const c1 = try filter.process(allocator, "<think>");
    defer {
        for (c1) |c| allocator.free(c);
        allocator.free(c1);
    }
    try std.testing.expectEqual(@as(usize, 0), c1.len);

    const c2 = try filter.process(allocator, "reasoning\n");
    defer {
        for (c2) |c| allocator.free(c);
        allocator.free(c2);
    }
    try std.testing.expectEqual(@as(usize, 0), c2.len);

    const c3 = try filter.process(allocator, "</think>");
    defer {
        for (c3) |c| allocator.free(c);
        allocator.free(c3);
    }

    // Text longer than max tag prefix (7 chars) to trigger check_len == 7
    const c4 = try filter.process(allocator, "This is a long response about quantum computing");
    defer {
        for (c4) |c| allocator.free(c);
        allocator.free(c4);
    }

    var result = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer result.deinit(allocator);
    for (c4) |chunk| {
        try result.appendSlice(allocator, chunk);
    }
    // Should emit most of the text (holding back potential tag prefix at end)
    try std.testing.expect(result.items.len > 0);
}
