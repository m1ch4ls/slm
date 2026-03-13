const std = @import("std");
const llama = @import("llama_api.zig");

pub const TokenBudget = struct {
    system_tokens: usize,
    user_prompt_tokens: usize,
    stdin_tokens: usize,
    output_tokens: usize,
    overhead_tokens: usize,
    context_size: usize,

    pub fn availableForStdin(self: TokenBudget) i64 {
        const used = @as(i64, @intCast(self.system_tokens)) +
            @as(i64, @intCast(self.user_prompt_tokens)) +
            @as(i64, @intCast(self.output_tokens)) +
            @as(i64, @intCast(self.overhead_tokens));
        const total: i64 = @intCast(self.context_size);
        return total - used;
    }
};

pub fn countTokensExact(vocab: *llama.Vocab, text: []const u8) usize {
    const n = llama.countTokens(vocab, text);
    if (n <= 0) return 0;
    return @intCast(n);
}

pub fn truncateForTokenBudget(
    allocator: std.mem.Allocator,
    vocab: *llama.Vocab,
    text: []const u8,
    max_tokens: usize,
) ![]const u8 {
    const total_tokens = countTokensExact(vocab, text);
    if (total_tokens <= max_tokens) {
        return try allocator.dupe(u8, text);
    }

    var start: usize = 0;
    var end: usize = text.len;
    var best_pos: usize = 0;

    while (start < end) {
        const mid = start + (end - start) / 2;
        const tokens = countTokensExact(vocab, text[0..mid]);

        if (tokens <= max_tokens) {
            best_pos = mid;
            start = mid + 1;
        } else {
            end = mid;
        }
    }

    return try allocator.dupe(u8, text[0..best_pos]);
}

pub fn formatChat(
    allocator: std.mem.Allocator,
    vocab: *llama.Vocab,
    system_prompt: []const u8,
    user_prompt: []const u8,
    stdin_content: []const u8,
    max_tokens: usize,
) ![]const u8 {
    const system_tokens = countTokensExact(vocab, system_prompt);
    const overhead_tokens: usize = 100;
    const available = if (max_tokens > system_tokens + overhead_tokens)
        max_tokens - system_tokens - overhead_tokens
    else
        0;

    var user_message: []const u8 = undefined;
    var needs_free = false;

    if (stdin_content.len > 0) {
        user_message = try std.fmt.allocPrint(
            allocator,
            "<instructions>{s}</instructions>\n\n<input>{s}</input>",
            .{ user_prompt, stdin_content },
        );
        needs_free = true;
    } else {
        user_message = user_prompt;
    }
    defer if (needs_free) allocator.free(user_message);

    _ = available;
    return try allocator.dupe(u8, user_message);
}
