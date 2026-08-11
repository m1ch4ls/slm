const std = @import("std");

pub const Capture = struct {
    processable: []u8,
    byte_count: u64,
    utf8_valid: bool,
    too_large: bool,

    pub fn deinit(self: *Capture, allocator: std.mem.Allocator) void {
        allocator.free(self.processable);
    }
};

pub const Options = struct {
    processing_byte_limit: u64,
    drain_oversized: bool,
    sink: ?*std.Io.Writer = null,
};

/// Reads Source input once, retaining only its processable prefix while optionally teeing all bytes.
pub fn capture(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    options: Options,
) !Capture {
    const memory_limit = std.math.cast(usize, options.processing_byte_limit) orelse
        return error.ProcessingByteLimitTooLarge;
    var processable: std.ArrayList(u8) = .empty;
    defer processable.deinit(allocator);

    var validator: Utf8Validator = .{};
    var byte_count: u64 = 0;
    var too_large = false;
    var buffer: [64 * 1024]u8 = undefined;

    while (true) {
        const retained: u64 = processable.items.len;
        const read_limit: usize = if (!options.drain_oversized and !too_large)
            @intCast(@min(@as(u64, buffer.len), options.processing_byte_limit - retained + 1))
        else
            buffer.len;
        var read_buffers = [_][]u8{buffer[0..read_limit]};
        const read = reader.readVec(&read_buffers) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (read == 0) continue;

        const bytes = buffer[0..read];
        if (options.sink) |sink| try sink.writeAll(bytes);
        validator.update(bytes);
        byte_count = try std.math.add(u64, byte_count, read);

        const remaining = memory_limit - processable.items.len;
        const retained_now = @min(remaining, bytes.len);
        const required_capacity = processable.items.len + retained_now;
        if (processable.capacity < required_capacity) {
            const bounded_capacity = @min(memory_limit, std.ArrayList(u8).growCapacity(required_capacity));
            try processable.ensureTotalCapacityPrecise(allocator, bounded_capacity);
        }
        processable.appendSliceAssumeCapacity(bytes[0..retained_now]);
        too_large = too_large or retained_now != bytes.len;
        if (too_large and !options.drain_oversized) break;
    }

    return .{
        .processable = try processable.toOwnedSlice(allocator),
        .byte_count = byte_count,
        .utf8_valid = validator.finish(),
        .too_large = too_large,
    };
}

const Utf8Validator = struct {
    valid: bool = true,
    continuation_count: u3 = 0,
    continuation_min: u8 = 0x80,
    continuation_max: u8 = 0xbf,

    fn update(self: *Utf8Validator, bytes: []const u8) void {
        for (bytes) |byte| self.updateByte(byte);
    }

    fn updateByte(self: *Utf8Validator, byte: u8) void {
        if (!self.valid) return;
        if (self.continuation_count != 0) {
            if (byte < self.continuation_min or byte > self.continuation_max) {
                self.valid = false;
                return;
            }
            self.continuation_count -= 1;
            self.continuation_min = 0x80;
            self.continuation_max = 0xbf;
            return;
        }

        switch (byte) {
            0x00...0x7f => {},
            0xc2...0xdf => self.continuation_count = 1,
            0xe0 => {
                self.continuation_count = 2;
                self.continuation_min = 0xa0;
            },
            0xe1...0xec, 0xee...0xef => self.continuation_count = 2,
            0xed => {
                self.continuation_count = 2;
                self.continuation_max = 0x9f;
            },
            0xf0 => {
                self.continuation_count = 3;
                self.continuation_min = 0x90;
            },
            0xf1...0xf3 => self.continuation_count = 3,
            0xf4 => {
                self.continuation_count = 3;
                self.continuation_max = 0x8f;
            },
            else => self.valid = false,
        }
    }

    fn finish(self: Utf8Validator) bool {
        return self.valid and self.continuation_count == 0;
    }
};

test "capture classifies boundaries and controls oversized draining" {
    const allocator = std.testing.allocator;
    var sink_storage: [32]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_storage);

    var reader_buffer: [2]u8 = undefined;
    var reader = std.testing.Reader.init(&reader_buffer, &.{
        .{ .buffer = "ab" },
        .{ .buffer = "cd" },
        .{ .buffer = "ef" },
    });
    reader.artificial_limit = .limited(1);
    var captured = try capture(allocator, &reader.interface, .{
        .processing_byte_limit = 4,
        .drain_oversized = true,
        .sink = &sink,
    });
    defer captured.deinit(allocator);

    try std.testing.expectEqualStrings("abcd", captured.processable);
    try std.testing.expectEqual(@as(u64, 6), captured.byte_count);
    try std.testing.expect(captured.utf8_valid);
    try std.testing.expect(captured.too_large);
    try std.testing.expectEqualStrings("abcdef", sink.buffered());

    var early_reader_buffer: [8]u8 = undefined;
    var early_reader = std.testing.Reader.init(&early_reader_buffer, &.{
        .{ .buffer = "abcdef" },
        .{ .buffer = "must remain unread" },
    });
    var early = try capture(allocator, &early_reader.interface, .{
        .processing_byte_limit = 4,
        .drain_oversized = false,
    });
    defer early.deinit(allocator);
    try std.testing.expectEqualStrings("abcd", early.processable);
    try std.testing.expectEqual(@as(u64, 5), early.byte_count);
    try std.testing.expect(early.too_large);
    try std.testing.expectEqual(@as(usize, 1), early_reader.next_call_index);
}

test "capture handles empty, exact-limit, split UTF-8, invalid input, and precedence" {
    const allocator = std.testing.allocator;

    const Case = struct {
        calls: []const std.testing.Reader.Call,
        limit: u64,
        valid: bool,
        too_large: bool,
        count: u64,
    };
    const cases = [_]Case{
        .{ .calls = &.{}, .limit = 4, .valid = true, .too_large = false, .count = 0 },
        .{ .calls = &.{.{ .buffer = "abcd" }}, .limit = 4, .valid = true, .too_large = false, .count = 4 },
        .{ .calls = &.{ .{ .buffer = "\xe2" }, .{ .buffer = "\x82" }, .{ .buffer = "\xac" } }, .limit = 4, .valid = true, .too_large = false, .count = 3 },
        .{ .calls = &.{.{ .buffer = "a\xffb" }}, .limit = 4, .valid = false, .too_large = false, .count = 3 },
        .{ .calls = &.{ .{ .buffer = "abcd" }, .{ .buffer = "\xff" } }, .limit = 4, .valid = false, .too_large = true, .count = 5 },
    };

    for (cases) |case| {
        var reader_buffer: [2]u8 = undefined;
        var reader = std.testing.Reader.init(&reader_buffer, case.calls);
        reader.artificial_limit = .limited(1);
        var captured = try capture(allocator, &reader.interface, .{
            .processing_byte_limit = case.limit,
            .drain_oversized = true,
        });
        defer captured.deinit(allocator);
        try std.testing.expectEqual(case.count, captured.byte_count);
        try std.testing.expectEqual(case.valid, captured.utf8_valid);
        try std.testing.expectEqual(case.too_large, captured.too_large);
    }
}

test "capture propagates read and sink failures" {
    const allocator = std.testing.allocator;

    var failing_reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.ReadFailed, capture(allocator, &failing_reader, .{
        .processing_byte_limit = 4,
        .drain_oversized = true,
    }));

    var reader: std.Io.Reader = .fixed("source");
    var failing_sink: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, capture(allocator, &reader, .{
        .processing_byte_limit = 4,
        .drain_oversized = true,
        .sink = &failing_sink,
    }));
}
