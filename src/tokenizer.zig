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

/// Compute max tokens available for stdin content given context constraints.
/// Returns 0 if no room is available (prompt + generation + overhead exceed context).
pub fn computeStdinBudget(
    n_ctx: u32,
    prompt_tokens: usize,
    max_gen_tokens: u32,
    template_overhead: usize,
) usize {
    const reserved = prompt_tokens + template_overhead + @as(usize, max_gen_tokens);
    return if (n_ctx > reserved)
        n_ctx - @as(u32, @intCast(reserved))
    else
        0;
}

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

    const truncated = try truncateForTokenBudget(allocator, vocab, user_message, available);
    if (needs_free) allocator.free(user_message);
    return truncated;
}

test "TokenBudget.availableForStdin - basic calculation" {
    const budget = TokenBudget{
        .system_tokens = 100,
        .user_prompt_tokens = 50,
        .stdin_tokens = 0,
        .output_tokens = 500,
        .overhead_tokens = 50,
        .context_size = 4096,
    };

    const available = budget.availableForStdin();
    try std.testing.expectEqual(@as(i64, 3396), available);
}

test "TokenBudget.availableForStdin - exactly full" {
    const budget = TokenBudget{
        .system_tokens = 1000,
        .user_prompt_tokens = 1000,
        .stdin_tokens = 0,
        .output_tokens = 1000,
        .overhead_tokens = 50,
        .context_size = 4050,
    };

    const available = budget.availableForStdin();
    try std.testing.expectEqual(@as(i64, 1000), available);
}

test "TokenBudget.availableForStdin - over budget" {
    const budget = TokenBudget{
        .system_tokens = 2000,
        .user_prompt_tokens = 2000,
        .stdin_tokens = 0,
        .output_tokens = 2000,
        .overhead_tokens = 100,
        .context_size = 4096,
    };

    const available = budget.availableForStdin();
    try std.testing.expectEqual(@as(i64, -2004), available);
}

test "TokenBudget.availableForStdin - shows usage after stdin allocated" {
    const budget = TokenBudget{
        .system_tokens = 100,
        .user_prompt_tokens = 50,
        .stdin_tokens = 500,
        .output_tokens = 500,
        .overhead_tokens = 50,
        .context_size = 4096,
    };

    const available = budget.availableForStdin();
    try std.testing.expectEqual(@as(i64, 3396), available);
}

test "TokenBudget.availableForStdin - small context" {
    const budget = TokenBudget{
        .system_tokens = 50,
        .user_prompt_tokens = 25,
        .stdin_tokens = 0,
        .output_tokens = 25,
        .overhead_tokens = 10,
        .context_size = 512,
    };

    const available = budget.availableForStdin();
    try std.testing.expectEqual(@as(i64, 402), available);
}

test "computeStdinBudget - normal case with room for stdin" {
    // 32k context, 10 prompt tokens, 512 gen tokens, 100 overhead
    // budget = 32768 - 10 - 512 - 100 = 32146
    const budget = computeStdinBudget(32768, 10, 512, 100);
    try std.testing.expectEqual(@as(usize, 32146), budget);
}

test "computeStdinBudget - large generation reserve" {
    // 32k context, 50 prompt tokens, 10240 gen tokens, 100 overhead
    // budget = 32768 - 50 - 10240 - 100 = 22378
    const budget = computeStdinBudget(32768, 50, 10240, 100);
    try std.testing.expectEqual(@as(usize, 22378), budget);
}

test "computeStdinBudget - no room left returns zero" {
    // 4096 context, 2000 prompt tokens, 2000 gen tokens, 100 overhead
    // reserved = 4100 > 4096, so 0
    const budget = computeStdinBudget(4096, 2000, 2000, 100);
    try std.testing.expectEqual(@as(usize, 0), budget);
}

test "computeStdinBudget - exactly full returns zero" {
    // reserved = 100 + 512 + 100 = 712, context = 712
    const budget = computeStdinBudget(712, 100, 512, 100);
    try std.testing.expectEqual(@as(usize, 0), budget);
}

test "computeStdinBudget - one token of room" {
    const budget = computeStdinBudget(713, 100, 512, 100);
    try std.testing.expectEqual(@as(usize, 1), budget);
}

test "computeStdinBudget - small context overwhelmed by gen tokens" {
    // 2048 context but requesting 4096 generation tokens
    const budget = computeStdinBudget(2048, 10, 4096, 100);
    try std.testing.expectEqual(@as(usize, 0), budget);
}

test "computeStdinBudget - zero prompt tokens" {
    const budget = computeStdinBudget(8192, 0, 512, 100);
    try std.testing.expectEqual(@as(usize, 7580), budget);
}

test "computeStdinBudget - zero gen tokens" {
    const budget = computeStdinBudget(4096, 50, 0, 100);
    try std.testing.expectEqual(@as(usize, 3946), budget);
}
