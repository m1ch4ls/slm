const std = @import("std");
const llama = @import("llama_api.zig");
const think_filter = @import("think_filter.zig");
const tokenizer = @import("tokenizer.zig");

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
    n_batch: u32,
    system_prompt: ?[*:0]const u8,

    /// Initialize inference engine with model and context
    pub fn init(
        allocator: std.mem.Allocator,
        model: *llama.ModelHandle,
        ctx: *llama.ContextHandle,
        system_prompt: ?[*:0]const u8,
    ) InferenceEngine {
        const n_ctx = llama.llama_n_ctx(ctx.ctx);
        return .{
            .model = model,
            .ctx = ctx,
            .vocab = model.vocab,
            .allocator = allocator,
            .chat_template = model.getChatTemplate(),
            .n_batch = @min(n_ctx, 2048),
            .system_prompt = system_prompt,
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
        const formatted_prompt = try self.formatPrompt(prompt, stdin, options.max_tokens);
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
        var sparams = llama.llama_sampler_chain_default_params();
        sparams.no_perf = true;
        const sampler = llama.llama_sampler_chain_init(sparams);
        defer llama.llama_sampler_free(sampler);

        if (options.temperature) |temp| {
            llama.llama_sampler_chain_add(sampler, llama.llama_sampler_init_min_p(0.05, 1));
            llama.llama_sampler_chain_add(sampler, llama.llama_sampler_init_temp(temp));
            llama.llama_sampler_chain_add(sampler, llama.llama_sampler_init_dist(options.seed));
        } else {
            llama.llama_sampler_chain_add(sampler, llama.llama_sampler_init_greedy());
        }

        // Setup think filter
        //var filter = try think_filter.ThinkFilter.init(self.allocator);
        //defer filter.deinit();

        var generated_tokens: u32 = 0;

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

            log.debug("Sampled text: {s}", .{token_text});

            // Apply think filter
            // const chunks_to_emit = try filter.process(self.allocator, token_text);
            // defer {
            //     for (chunks_to_emit) |chunk| {
            //         self.allocator.free(chunk);
            //     }
            //     self.allocator.free(chunks_to_emit);
            // }

            // Emit chunks via callback
            // for (chunks_to_emit) |chunk| {
            //     if (chunk.len > 0) {
            //         continue_generation = callback(chunk, userdata);
            //         if (!continue_generation) break;
            //     }
            // }
            continue_generation = callback(token_text, userdata);
            if (!continue_generation) break;

            // Decode next token (position tracked automatically)
            var token_arr = [_]llama.Token{new_token};
            const batch = llama.llama_batch_get_one(&token_arr, 1);
            const decode_result = llama.llama_decode(self.ctx.ctx, batch);
            if (decode_result != 0) {
                log.err("llama_decode failed for generated token with code {d}", .{decode_result});
                return InferenceError.DecodeFailed;
            }
        }

        if (generated_tokens >= options.max_tokens) {
            hit_token_limit = true;
        }

        // // Flush remaining content
        // if (continue_generation) {
        //     if (try filter.flush(self.allocator)) |remaining| {
        //         defer self.allocator.free(remaining);
        //         _ = callback(remaining, userdata);
        //     }
        // }

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
            .stopped_by_eos = stopped_by_eos,
            .hit_token_limit = hit_token_limit,
        };
    }

    /// Format prompt using chat template if available
    fn formatPrompt(
        self: *InferenceEngine,
        prompt: []const u8,
        stdin: []const u8,
        max_gen_tokens: u32,
    ) ![]const u8 {
        const has_stdin = stdin.len > 0;

        // Truncate stdin to fit within context budget
        const effective_stdin = if (has_stdin) blk: {
            const n_ctx = llama.llama_n_ctx(self.ctx.ctx);
            //const system_prompt_tokens = if (self.system_prompt) |sp| tokenizer.countTokensExact(self.vocab, std.mem.span(sp)) else 0;
            const prompt_tokens = tokenizer.countTokensExact(self.vocab, prompt);
            const template_overhead: usize = 5000;
            const max_stdin_tokens = tokenizer.computeStdinBudget(n_ctx, prompt_tokens, max_gen_tokens, template_overhead);

            log.debug("Token budget: n_ctx={d}, prompt={d}, gen={d}, overhead={d}, stdin_budget={d}", .{
                n_ctx, prompt_tokens, max_gen_tokens, template_overhead, max_stdin_tokens,
            });

            if (max_stdin_tokens == 0) break :blk try self.allocator.dupe(u8, "");
            break :blk try tokenizer.truncateForTokenBudget(self.allocator, self.vocab, stdin, max_stdin_tokens);
        } else try self.allocator.dupe(u8, stdin);
        defer self.allocator.free(effective_stdin);

        const effective_has_stdin = effective_stdin.len > 0;

        if (self.chat_template != null) {
            // Use chat template formatting
            const user_content = if (effective_has_stdin)
                try std.fmt.allocPrint(self.allocator, "<instructions>{s}</instructions>\n\n<input>{s}</input>", .{ prompt, effective_stdin })
            else
                try self.allocator.dupe(u8, prompt);
            defer self.allocator.free(user_content);

            const user_content_z = try self.allocator.dupeZ(u8, user_content);
            defer self.allocator.free(user_content_z);

            // Build messages array with optional system prompt
            var messages: [2]llama.ChatMessage = undefined;
            var msg_count: usize = 0;

            if (self.system_prompt) |sp| {
                messages[0] = .{ .role = "system", .content = sp };
                msg_count += 1;
            }
            messages[msg_count] = .{ .role = "user", .content = user_content_z.ptr };
            msg_count += 1;

            return try self.model.applyChatTemplate(
                self.allocator,
                messages[0..msg_count],
                true, // Add assistant marker
            );
        } else {
            // Raw prompt formatting
            if (effective_has_stdin) {
                return try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ prompt, effective_stdin });
            } else {
                return try self.allocator.dupe(u8, prompt);
            }
        }
    }

    /// Decode the initial batch of prompt tokens
    fn decodeInitialBatch(self: *InferenceEngine, tokens: []const llama.Token) InferenceError!void {
        const batch_size: usize = @intCast(self.n_batch);
        var offset: usize = 0;

        while (offset < tokens.len) {
            const remaining = tokens.len - offset;
            const chunk_len = @min(remaining, batch_size);

            // Use llama_batch_get_one for automatic position tracking
            // Need a mutable copy of the token slice for this chunk
            const batch = llama.llama_batch_get_one(
                @constCast(tokens[offset..].ptr),
                @intCast(chunk_len),
            );

            const decode_result = llama.llama_decode(self.ctx.ctx, batch);
            if (decode_result != 0) {
                log.err("llama_decode failed with code {d}", .{decode_result});
                return InferenceError.DecodeFailed;
            }

            offset += chunk_len;
        }
    }
};
