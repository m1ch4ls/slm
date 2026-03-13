const std = @import("std");

const log = std.log.scoped(.think_filter);

pub const OutputBuffer = struct {
    chunks: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !OutputBuffer {
        return .{
            .chunks = try std.ArrayList([]const u8).initCapacity(allocator, 16),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OutputBuffer) void {
        for (self.chunks.items) |chunk| {
            self.allocator.free(chunk);
        }
        self.chunks.deinit(self.allocator);
    }

    pub fn append(self: *OutputBuffer, text: []const u8) !void {
        const copy = try self.allocator.dupe(u8, text);
        try self.chunks.append(self.allocator, copy);
    }

    pub fn isEmpty(self: *const OutputBuffer) bool {
        return self.chunks.items.len == 0;
    }
};

pub const ThinkFilter = struct {
    buffer: []u8,
    buffer_len: usize,
    in_think: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ThinkFilter {
        const buf = try allocator.alloc(u8, 4096);
        return .{
            .buffer = buf,
            .buffer_len = 0,
            .in_think = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ThinkFilter) void {
        self.allocator.free(self.buffer);
    }

    pub fn process(self: *ThinkFilter, token_text: []const u8, output: *OutputBuffer) !void {
        if (self.buffer_len + token_text.len > self.buffer.len) {
            const new_size = self.buffer.len * 2 + token_text.len;
            const new_buf = try self.allocator.alloc(u8, new_size);
            @memcpy(new_buf[0..self.buffer_len], self.buffer[0..self.buffer_len]);
            self.allocator.free(self.buffer);
            self.buffer = new_buf;
        }
        @memcpy(self.buffer[self.buffer_len .. self.buffer_len + token_text.len], token_text);
        self.buffer_len += token_text.len;
        try self.flushBuffer(output, false);
    }

    fn flushBuffer(self: *ThinkFilter, output: *OutputBuffer, comptime is_final: bool) !void {
        var emit_start: usize = 0;
        var i: usize = 0;

        while (i < self.buffer_len) {
            if (!self.in_think) {
                // Look for <think> opening tag
                if (i + 7 <= self.buffer_len and std.mem.eql(u8, self.buffer[i .. i + 7], "<think>")) {
                    // Emit content before the think tag
                    if (emit_start < i) {
                        try output.append(self.buffer[emit_start..i]);
                    }
                    self.in_think = true;
                    i += 7;
                    emit_start = i;
                } else {
                    i += 1;
                }
            } else {
                // Inside think block, look for </think> closing tag
                if (i + 8 <= self.buffer_len and std.mem.eql(u8, self.buffer[i .. i + 8], "</think>")) {
                    log.debug("Found </think> at i={}", .{i});
                    self.in_think = false;
                    i += 8;
                    emit_start = i;
                } else {
                    i += 1;
                }
            }
        }

        // Emit any remaining content outside think blocks
        if (!self.in_think and emit_start < self.buffer_len) {
            // When not final, we need to be careful about partial tags at the end
            const safe_end = if (is_final) self.buffer_len else blk: {
                // Don't emit if buffer ends with potential start of a tag
                var end = self.buffer_len;
                while (end > emit_start) : (end -= 1) {
                    // Check if we might be in the middle of a tag
                    const c = self.buffer[end - 1];
                    if (c == '<') {
                        // Could be start of <think> or </think>
                        break :blk end - 1;
                    }
                    if (c == '>' or std.ascii.isAlphabetic(c) or c == '/') {
                        // We're past any potential partial tag
                        break :blk end;
                    }
                }
                break :blk end;
            };

            if (emit_start < safe_end) {
                try output.append(self.buffer[emit_start..safe_end]);
                emit_start = safe_end;
            }
        }

        // Keep unprocessed content (partial tags or think block content) in buffer
        const remaining = self.buffer_len - emit_start;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.buffer[0..remaining], self.buffer[emit_start..self.buffer_len]);
        }
        self.buffer_len = remaining;
    }

    pub fn flush(self: *ThinkFilter, output: *OutputBuffer) !void {
        try self.flushBuffer(output, true);
    }
};
