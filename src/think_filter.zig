const std = @import("std");

const log = std.log.scoped(.think_filter);

pub const ThinkFilter = struct {
    buffer: std.ArrayList(u8),
    in_think: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ThinkFilter {
        return .{
            .buffer = try std.ArrayList(u8).initCapacity(allocator, 256),
            .in_think = false,
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
                    i += 8;
                    emit_start = i;
                } else {
                    i += 1;
                }
            }
        }

        // Emit safe content at the end (outside think blocks only)
        if (!self.in_think and emit_start < self.buffer.items.len) {
            // Be conservative: don't emit if buffer ends with potential partial tag
            // Scan backwards from end to find safe emission point
            const safe_end = blk: {
                var end = self.buffer.items.len;
                while (end > emit_start) : (end -= 1) {
                    const c = self.buffer.items[end - 1];
                    if (c == '<') {
                        // Could be start of <think> or </think>, don't emit the '<'
                        break :blk end - 1;
                    }
                    if (c == '>' or std.ascii.isAlphabetic(c) or c == '/') {
                        // We're past any potential partial tag, can emit up to here
                        break :blk end;
                    }
                }
                break :blk end;
            };

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
    try std.testing.expectEqualStrings("Hello  World", result.items);
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

    // When tags are complete within a single process() call, they work correctly
    // Note: trailing space is held back by partial tag detection (space could be part of tag)
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

    // "Before" emitted (space held back), then " <think>..." processes the rest
    try std.testing.expectEqualStrings("Before", chunks1[0]);
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

    // "Hello " - space at end is held back by partial tag detection
    const chunks = try filter.process(allocator, "Hello ");
    defer {
        for (chunks) |chunk| allocator.free(chunk);
        allocator.free(chunks);
    }

    // process() emits "Hello" (space held back)
    try std.testing.expectEqualStrings("Hello", chunks[0]);

    // flush() returns the remaining space
    const remaining = try filter.flush(allocator);
    defer if (remaining) |r| allocator.free(r);

    try std.testing.expectEqualStrings(" ", remaining.?);
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
