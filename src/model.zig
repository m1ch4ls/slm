const std = @import("std");

pub const schema_version: u32 = 1;
pub const request_format_version: u32 = 1;
pub const processing_byte_limit: u64 = 16 * 1024 * 1024;

pub const Output = union(enum) {
    content: []u8,
    refusal: []u8,

    pub fn bytes(self: Output) []const u8 {
        return switch (self) {
            inline else => |text| text,
        };
    }

    pub fn kind(self: Output) []const u8 {
        return switch (self) {
            .content => "content",
            .refusal => "refusal",
        };
    }

    pub fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes());
    }
};

pub const Usage = struct {
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    total_tokens: ?u64 = null,

    pub fn isPresent(self: Usage) bool {
        return self.prompt_tokens != null or
            self.completion_tokens != null or
            self.total_tokens != null;
    }
};

pub const Completion = struct {
    output: Output,
    finish_reason: ?[]u8 = null,
    usage: Usage = .{},

    pub fn deinit(self: *Completion, allocator: std.mem.Allocator) void {
        self.output.deinit(allocator);
        if (self.finish_reason) |value| allocator.free(value);
    }
};

pub const RequestFailure = union(enum) {
    network: []const u8,
    http_status: u16,
};

pub const ResponseInvalidReason = enum {
    malformed_json,
    empty_choices,
    missing_output,
    response_too_large,
    ambiguous_output,
};

pub const CompletionResult = union(enum) {
    completion: Completion,
    request_failed: RequestFailure,
    response_invalid: ResponseInvalidReason,

    pub fn deinit(self: *CompletionResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completion => |*completion| completion.deinit(allocator),
            .request_failed, .response_invalid => {},
        }
    }
};
