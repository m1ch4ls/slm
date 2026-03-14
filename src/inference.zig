const std = @import("std");
const llama = @import("llama_api.zig");
const think_filter = @import("think_filter.zig");

const log = std.log.scoped(.inference);

/// Errors that can occur during inference
pub const InferenceError = error{
    DecodeFailed,
    TokenizationFailed,
    ContextFull,
    InvalidPrompt,
};

/// Configuration options for inference
pub const InferenceOptions = struct {
    /// Maximum tokens to generate
    max_tokens: u32 = 512,
    /// Antiprompts that trigger stopping when detected in output
    antiprompts: []const []const u8 = &[_][]const u8{"<|im_start|>"},
    /// Whether to use chat template formatting
    use_chat_template: bool = true,
    /// Whether to filter think blocks from output
    filter_think_blocks: bool = true,
    /// Temperature for sampling (if null, uses greedy)
    temperature: ?f32 = null,
    /// Random seed for sampling (only used with temperature)
    seed: u32 = 0,
};

/// Statistics from a generation run
pub const GenerationStats = struct {
    /// Number of prompt tokens
    prompt_tokens: usize,
    /// Number of generated tokens
    generated_tokens: usize,
    /// Total tokens processed
    total_tokens: usize,
    /// Time spent in milliseconds
    elapsed_ms: u64,
    /// Tokens per second
    tokens_per_second: f64,
    /// Whether generation was stopped by antiprompt
    stopped_by_antiprompt: bool,
    /// Whether generation was stopped by EOS
    stopped_by_eos: bool,
    /// Whether generation hit max_tokens limit
    hit_token_limit: bool,
};

/// Callback for receiving generated tokens
/// Return false to stop generation early
pub const TokenCallback = *const fn (chunk: []const u8, userdata: ?*anyopaque) bool;

/// Engine for running inference
pub const InferenceEngine = struct {
    model: *llama.ModelHandle,
    ctx: *llama.ContextHandle,
    vocab: *llama.Vocab,
    allocator: std.mem.Allocator,
    chat_template: ?[*:0]const u8,

    /// Initialize inference engine with model and context
    pub fn init(
        allocator: std.mem.Allocator,
        model: *llama.ModelHandle,
        ctx: *llama.ContextHandle,
    ) InferenceEngine {
        return .{
            .model = model,
            .ctx = ctx,
            .vocab = model.vocab,
            .allocator = allocator,
            .chat_template = model.getChatTemplate(),
        };
    }

    /// Generate text from a prompt
    /// Calls `callback` with each chunk of generated text
    pub fn generate(
        self: *InferenceEngine,
        prompt: []const u8,
        stdin: []const u8,
        options: InferenceOptions,
        callback: TokenCallback,
        userdata: ?*anyopaque,
    ) !GenerationStats {
        const start_time = std.time.milliTimestamp();

        // Clear memory for fresh generation
        const memory = llama.llama_get_memory(self.ctx.ctx);
        if (memory) |mem| {
            llama.llama_memory_clear(mem);
        }

        // Format prompt
        const formatted_prompt = try self.formatPrompt(prompt, stdin, options.use_chat_template);
        defer self.allocator.free(formatted_prompt);

        log.debug("Formatted prompt ({d} bytes): {s}", .{
            formatted_prompt.len,
            formatted_prompt[0..@min(500, formatted_prompt.len)],
        });

        // Tokenize
        const add_bos = llama.llama_vocab_get_add_bos(self.vocab);
        const tokens = try llama.tokenize(self.allocator, self.vocab, formatted_prompt, add_bos);
        defer self.allocator.free(tokens);

        log.debug("Tokenized to {d} tokens (add_bos={})", .{ tokens.len, add_bos });

        // Initial decode
        try self.decodeInitialBatch(tokens);

        // Setup sampling
        const sampler = if (options.temperature) |_|
            llama.llama_sampler_init_dist(options.seed)
        else
            llama.llama_sampler_init_greedy();
        defer llama.llama_sampler_free(sampler);

        // Setup think filter if enabled
        var filter: ?think_filter.ThinkFilter = null;
        if (options.filter_think_blocks) {
            filter = try think_filter.ThinkFilter.init(self.allocator);
        }
        defer if (filter) |*f| f.deinit();

        var generated_tokens: u32 = 0;
        var pos: i32 = @intCast(tokens.len);
        var output_buffer = try std.ArrayList(u8).initCapacity(self.allocator, 1024);
        defer output_buffer.deinit(self.allocator);

        var stopped_by_antiprompt = false;
        var stopped_by_eos = false;
        var hit_token_limit = false;
        var continue_generation = true;

        while (generated_tokens < options.max_tokens and continue_generation) : (generated_tokens += 1) {
            const new_token = llama.llama_sampler_sample(sampler, self.ctx.ctx, -1);

            log.debug("Sampled token: {d}", .{new_token});

            // Check for EOS
            if (new_token == llama.TokenNull or llama.llama_vocab_is_eog(self.vocab, new_token)) {
                log.debug("EOS token detected (token={d}), stopping", .{new_token});
                stopped_by_eos = true;
                break;
            }

            // Detokenize
            const token_text = try llama.detokenize(self.allocator, self.vocab, new_token);
            defer self.allocator.free(token_text);

            // Check antiprompts
            if (try self.checkAntiprompts(
                token_text,
                &output_buffer,
                options.antiprompts,
                callback,
                userdata,
            )) |result| {
                stopped_by_antiprompt = true;
                continue_generation = result;
                break;
            }

            // Apply think filter if enabled
            const chunks_to_emit = if (filter) |*f|
                try f.process(self.allocator, token_text)
            else blk: {
                const chunk = try self.allocator.dupe(u8, token_text);
                const arr = try self.allocator.alloc([]const u8, 1);
                arr[0] = chunk;
                break :blk arr;
            };
            defer {
                for (chunks_to_emit) |chunk| {
                    self.allocator.free(chunk);
                }
                self.allocator.free(chunks_to_emit);
            }

            // Emit chunks via callback
            for (chunks_to_emit) |chunk| {
                if (chunk.len > 0) {
                    continue_generation = callback(chunk, userdata);
                    if (!continue_generation) break;
                }
            }

            // Decode next token
            try self.decodeSingleToken(new_token, pos);
            pos += 1;
        }

        if (generated_tokens >= options.max_tokens) {
            hit_token_limit = true;
        }

        // Flush remaining content
        if (continue_generation) {
            if (filter) |*f| {
                if (try f.flush(self.allocator)) |remaining| {
                    defer self.allocator.free(remaining);
                    _ = callback(remaining, userdata);
                }
            }
        }

        const elapsed_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        const tokens_per_second = if (elapsed_ms > 0)
            @as(f64, @floatFromInt(generated_tokens)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0)
        else
            0.0;

        return GenerationStats{
            .prompt_tokens = tokens.len,
            .generated_tokens = generated_tokens,
            .total_tokens = tokens.len + generated_tokens,
            .elapsed_ms = elapsed_ms,
            .tokens_per_second = tokens_per_second,
            .stopped_by_antiprompt = stopped_by_antiprompt,
            .stopped_by_eos = stopped_by_eos,
            .hit_token_limit = hit_token_limit,
        };
    }

    /// Format prompt with or without chat template
    fn formatPrompt(
        self: *InferenceEngine,
        prompt: []const u8,
        stdin: []const u8,
        use_chat_template: bool,
    ) ![]const u8 {
        const has_stdin = stdin.len > 0;

        if (use_chat_template and self.chat_template != null) {
            // Use chat template formatting
            const user_content = if (has_stdin)
                try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ prompt, stdin })
            else
                try self.allocator.dupe(u8, prompt);
            defer self.allocator.free(user_content);

            const user_content_z = try self.allocator.dupeZ(u8, user_content);
            defer self.allocator.free(user_content_z);

            const role_z = "user";
            const messages = [_]llama.ChatMessage{
                .{ .role = role_z.ptr, .content = user_content_z.ptr },
            };

            return try self.model.applyChatTemplate(
                self.allocator,
                &messages,
                true, // Add assistant marker
            );
        } else {
            // Raw prompt formatting
            if (has_stdin) {
                return try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ prompt, stdin });
            } else {
                return try self.allocator.dupe(u8, prompt);
            }
        }
    }

    /// Decode the initial batch of prompt tokens
    fn decodeInitialBatch(self: *InferenceEngine, tokens: []const llama.Token) InferenceError!void {
        var batch = llama.llama_batch_init(@intCast(tokens.len), 0, 1);
        defer llama.llama_batch_free(batch);

        for (tokens, 0..) |token, i| {
            batch.token[i] = token;
            batch.pos[i] = @intCast(i);
            batch.n_seq_id[i] = 1;
            batch.seq_id[i][0] = 0;
            if (batch.logits) |logits| {
                logits[i] = if (i == tokens.len - 1) 1 else 0;
            }
        }
        batch.n_tokens = @intCast(tokens.len);
        if (batch.logits) |logits| {
            logits[@as(usize, @intCast(batch.n_tokens - 1))] = 1;
        }

        const decode_result = llama.llama_decode(self.ctx.ctx, batch);
        if (decode_result != 0) {
            log.err("llama_decode failed with code {d}", .{decode_result});
            return InferenceError.DecodeFailed;
        }
    }

    /// Decode a single generated token
    fn decodeSingleToken(self: *InferenceEngine, token: llama.Token, pos: i32) InferenceError!void {
        var batch = llama.llama_batch_init(1, 0, 1);
        defer llama.llama_batch_free(batch);

        batch.token[0] = token;
        batch.pos[0] = pos;
        batch.n_seq_id[0] = 1;
        batch.seq_id[0][0] = 0;
        if (batch.logits) |logits| {
            logits[0] = 1;
        }
        batch.n_tokens = 1;

        _ = llama.llama_decode(self.ctx.ctx, batch);
    }

    /// Check if antiprompts are detected in output
    /// Returns null if no antiprompt detected, or optional bool for whether to continue
    fn checkAntiprompts(
        self: *InferenceEngine,
        token_text: []const u8,
        output_buffer: *std.ArrayList(u8),
        antiprompts: []const []const u8,
        callback: TokenCallback,
        userdata: ?*anyopaque,
    ) !?bool {
        try output_buffer.appendSlice(self.allocator, token_text);
        const recent_output = output_buffer.items;

        for (antiprompts) |antiprompt| {
            if (recent_output.len >= antiprompt.len) {
                const end_slice = recent_output[recent_output.len - antiprompt.len ..];
                if (std.mem.eql(u8, end_slice, antiprompt)) {
                    log.debug("Detected antiprompt '{s}' in output, stopping generation", .{antiprompt});
                    // Don't emit the antiprompt itself
                    const content_to_emit = recent_output[0 .. recent_output.len - antiprompt.len];
                    if (content_to_emit.len > 0) {
                        _ = callback(content_to_emit, userdata);
                    }
                    return false; // Stop generation
                }
            }
        }

        return null; // No antiprompt detected
    }
};
