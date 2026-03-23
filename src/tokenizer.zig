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

/// Find a UTF-8 safe boundary at or before the given position.
/// Returns the position of the start of the current UTF-8 character.
pub fn findUtf8Boundary(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    if (pos > text.len) return text.len;
    if (pos == text.len) return pos;

    // Check if pos is already a valid boundary
    const b = text[pos];
    // If it's not a continuation byte (0x80-0xBF), it's a character start
    if (b & 0xC0 != 0x80) return pos;

    // Walk backwards to find the start of the UTF-8 character
    // Valid UTF-8:
    // 0xxxxxxx - ASCII (1 byte)
    // 110xxxxx - start of 2-byte sequence
    // 1110xxxx - start of 3-byte sequence
    // 11110xxx - start of 4-byte sequence
    // 10xxxxxx - continuation byte (not a start)
    var i = pos;
    while (i > 0) {
        i -= 1;
        const byte = text[i];
        // If this is not a continuation byte, it's a character start
        if (byte & 0xC0 != 0x80) return i;
    }
    return 0;
}

/// Truncate text to fit within max_tokens using binary search over byte positions.
/// Counts tokens from text[0..probe] each iteration; must count from zero because
/// tokenizers are context-sensitive at boundaries (token at seam depends on prior bytes).
/// Known counts at lo and hi are threaded through to skip redundant tokenize calls
/// when a probe lands exactly on a boundary already measured.
pub fn truncateForTokenBudget(
    allocator: std.mem.Allocator,
    vocab: *llama.Vocab,
    text: []const u8,
    max_tokens: usize,
) ![]const u8 {
    if (text.len == 0 or max_tokens == 0) {
        return try allocator.dupe(u8, "");
    }

    const total_tokens = countTokensExact(vocab, text);
    if (total_tokens <= max_tokens) {
        return try allocator.dupe(u8, text);
    }

    var lo: usize = 0;
    var hi: usize = text.len;
    var best_pos: usize = 0;
    // known_lo: token count at text[0..lo]. Valid at lo=0 (count is 0);
    // becomes null whenever lo advances to an unmeasured byte position.
    var known_lo: ?usize = 0;
    // known_hi: token count at text[0..hi]. Always valid; starts as total_tokens.
    var known_hi: usize = total_tokens;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const test_pos = findUtf8Boundary(text, mid);

        const tokens = if (test_pos == hi)
            known_hi
        else if (test_pos == lo)
            (known_lo orelse countTokensExact(vocab, text[0..test_pos]))
        else
            countTokensExact(vocab, text[0..test_pos]);

        if (tokens <= max_tokens) {
            best_pos = test_pos;
            lo = test_pos + 1;
            known_lo = null;
        } else {
            hi = test_pos;
            known_hi = tokens;
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

test "findUtf8Boundary - ASCII" {
    const text = "hello world";
    try std.testing.expectEqual(@as(usize, 0), findUtf8Boundary(text, 0));
    try std.testing.expectEqual(@as(usize, 5), findUtf8Boundary(text, 5));
    try std.testing.expectEqual(@as(usize, 11), findUtf8Boundary(text, 11));
    try std.testing.expectEqual(@as(usize, 11), findUtf8Boundary(text, 100));
}

test "findUtf8Boundary - multi-byte UTF-8" {
    // "Hello 世界" - "世" is 3 bytes (E4 B8 96), "界" is 3 bytes (E7 95 8C)
    const text = "Hello 世界";
    // Byte positions: H=0, e=1, l=2, l=3, o=4, space=5, 世=6-8, 界=9-11

    // Cutting at byte 7 (middle of "世") should give us byte 6 (start of "世")
    try std.testing.expectEqual(@as(usize, 6), findUtf8Boundary(text, 7));
    try std.testing.expectEqual(@as(usize, 6), findUtf8Boundary(text, 8));

    // Cutting at byte 10 (middle of "界") should give us byte 9 (start of "界")
    try std.testing.expectEqual(@as(usize, 9), findUtf8Boundary(text, 10));
}

test "findUtf8Boundary - 4-byte UTF-8" {
    // Emoji 😀 (F0 9F 98 80) is 4 bytes
    const text = "ab😀cd";
    // Byte positions: a=0, b=1, 😀=2-5, c=6, d=7

    try std.testing.expectEqual(@as(usize, 2), findUtf8Boundary(text, 3));
    try std.testing.expectEqual(@as(usize, 2), findUtf8Boundary(text, 4));
    try std.testing.expectEqual(@as(usize, 2), findUtf8Boundary(text, 5));
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
