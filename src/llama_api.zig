const std = @import("std");

pub const Token = i32;
pub const TokenNull: Token = -1;

pub const Model = opaque {};
pub const Context = opaque {};
pub const Vocab = opaque {};
pub const Sampler = opaque {};

pub const ChatMessage = extern struct {
    role: [*:0]const u8,
    content: [*:0]const u8,
};

pub const ContextParams = extern struct {
    n_ctx: u32,
    n_batch: u32,
    n_ubatch: u32,
    n_seq_max: u32,
    n_threads: i32,
    n_threads_batch: i32,
    rope_scaling_type: i32,
    pooling_type: i32,
    attention_type: i32,
    flash_attn_type: i32,
    rope_freq_base: f32,
    rope_freq_scale: f32,
    yarn_ext_factor: f32,
    yarn_attn_factor: f32,
    yarn_beta_fast: f32,
    yarn_beta_slow: f32,
    yarn_orig_ctx: u32,
    defrag_thold: f32,
    cb_eval: ?*anyopaque,
    cb_eval_user_data: ?*anyopaque,
    type_k: i32,
    type_v: i32,
    abort_callback: ?*anyopaque,
    abort_callback_data: ?*anyopaque,
    embeddings: bool,
    offload_kqv: bool,
    no_perf: bool,
    op_offload: bool,
    swa_full: bool,
    kv_unified: bool,
    samplers: ?*anyopaque,
    n_samplers: usize,
};

pub const ModelParams = extern struct {
    devices: ?*anyopaque,
    tensor_buft_overrides: ?*const anyopaque,
    n_gpu_layers: i32,
    split_mode: i32,
    main_gpu: i32,
    tensor_split: ?*const f32,
    progress_callback: ?*const fn (f32, ?*anyopaque) callconv(.c) bool,
    progress_callback_user_data: ?*anyopaque,
    kv_overrides: ?*const anyopaque,
    vocab_only: bool,
    use_mmap: bool,
    use_direct_io: bool,
    use_mlock: bool,
    check_tensors: bool,
    use_extra_bufts: bool,
    no_host: bool,
    no_alloc: bool,
};

pub extern fn llama_model_load_from_file(path: [*:0]const u8, params: ModelParams) ?*Model;
pub extern fn llama_free_model(model: *Model) void;

pub extern fn llama_new_context_with_model(model: *Model, params: ContextParams) ?*Context;
pub extern fn llama_init_from_model(model: *Model, params: ContextParams) ?*Context;
pub extern fn llama_free(ctx: *Context) void;

pub extern fn llama_model_default_params() ModelParams;
pub extern fn llama_context_default_params() ContextParams;

pub extern fn llama_model_get_vocab(model: *Model) *Vocab;
pub extern fn llama_n_ctx(ctx: *Context) u32;

pub extern fn llama_tokenize(
    vocab: *Vocab,
    text: [*]const u8,
    text_len: i32,
    tokens: ?[*]Token,
    n_tokens_max: i32,
    add_special: bool,
    parse_special: bool,
) i32;

pub extern fn llama_token_to_piece(
    vocab: *Vocab,
    token: Token,
    buf: [*]u8,
    length: i32,
    lstrip: i32,
    special: bool,
) i32;

pub extern fn llama_vocab_is_eog(vocab: *Vocab, token: Token) bool;

pub extern fn llama_n_vocab(vocab: *Vocab) i32;

pub extern fn llama_vocab_bos(vocab: *Vocab) Token;
pub extern fn llama_vocab_eos(vocab: *Vocab) Token;
pub extern fn llama_vocab_get_add_bos(vocab: *Vocab) bool;
pub extern fn llama_vocab_get_add_eos(vocab: *Vocab) bool;

pub extern fn llama_model_chat_template(model: *Model, name: ?[*:0]const u8) ?[*:0]const u8;

pub extern fn llama_chat_apply_template(
    tmpl: ?[*:0]const u8,
    chat: [*]const ChatMessage,
    n_msg: usize,
    add_assistant: bool,
    buf: ?[*]u8,
    buf_len: i32,
) i32;

pub const Batch = extern struct {
    n_tokens: i32,
    token: [*]Token,
    embd: ?[*]f32,
    pos: [*]i32,
    n_seq_id: [*]i32,
    seq_id: [*][*]i32,
    logits: ?[*]i8,
};

pub extern fn llama_batch_init(n_tokens: i32, embd: i32, n_seq_max: i32) Batch;
pub extern fn llama_batch_get_one(tokens: [*]Token, n_tokens: i32) Batch;
pub extern fn llama_batch_free(batch: Batch) void;

pub extern fn llama_decode(ctx: *Context, batch: Batch) i32;
pub extern fn llama_get_logits(ctx: *Context) [*]f32;

pub extern fn llama_sampler_init_greedy() *Sampler;
pub extern fn llama_sampler_init_dist(seed: u32) *Sampler;
pub extern fn llama_sampler_init_temp(t: f32) *Sampler;
pub extern fn llama_sampler_init_min_p(p: f32, min_keep: usize) *Sampler;
pub extern fn llama_sampler_sample(smpl: *Sampler, ctx: *Context, idx: i32) Token;
pub extern fn llama_sampler_free(smpl: *Sampler) void;

pub const SamplerChainParams = extern struct {
    no_perf: bool,
};

pub extern fn llama_sampler_chain_default_params() SamplerChainParams;
pub extern fn llama_sampler_chain_init(params: SamplerChainParams) *Sampler;
pub extern fn llama_sampler_chain_add(chain: *Sampler, smpl: *Sampler) void;

pub extern fn llama_backend_init() void;
pub extern fn llama_backend_free() void;

pub extern fn ggml_backend_load_all() void;
pub extern fn ggml_backend_load_all_from_path(path: [*:0]const u8) void;

// Backend registration types and functions (for manual backend registration)
// Note: With GGML_BACKEND_DL, backends are loaded dynamically at runtime
// and these manual registration functions are not needed
pub const BackendReg = opaque {};

pub extern fn llama_get_memory(ctx: *Context) ?*anyopaque;
pub extern fn llama_memory_clear(mem: *anyopaque) void;

pub fn countTokens(vocab: *Vocab, text: []const u8) i32 {
    const result = llama_tokenize(
        vocab,
        text.ptr,
        @intCast(text.len),
        null,
        0,
        false,
        true,
    );
    return -result;
}

pub fn tokenize(
    allocator: std.mem.Allocator,
    vocab: *Vocab,
    text: []const u8,
    add_special: bool,
) ![]Token {
    const n_tokens = countTokens(vocab, text);
    if (n_tokens <= 0) return error.TokenizationFailed;

    const tokens = try allocator.alloc(Token, @intCast(n_tokens));
    errdefer allocator.free(tokens);

    const result = llama_tokenize(
        vocab,
        text.ptr,
        @intCast(text.len),
        tokens.ptr,
        n_tokens,
        add_special,
        true,
    );

    if (result != n_tokens) {
        allocator.free(tokens);
        return error.TokenizationFailed;
    }

    return tokens;
}

pub fn detokenize(
    allocator: std.mem.Allocator,
    vocab: *Vocab,
    token: Token,
) ![]u8 {
    var buf: [128]u8 = undefined;
    // special: true so that special tokens (e.g. <think>, </think>) produce
    // their text representation instead of empty strings
    const len = llama_token_to_piece(vocab, token, &buf, buf.len, 0, true);
    if (len < 0) return error.DetokenizationFailed;

    const result = try allocator.alloc(u8, @intCast(len));
    @memcpy(result, buf[0..@intCast(len)]);
    return result;
}

pub const ModelHandle = struct {
    model: *Model,
    vocab: *Vocab,
    allocator: std.mem.Allocator,

    pub fn load(allocator: std.mem.Allocator, path: []const u8, params: ModelParams) !ModelHandle {
        const cstr = try allocator.dupeZ(u8, path);
        defer allocator.free(cstr);

        const model = llama_model_load_from_file(cstr.ptr, params) orelse return error.ModelLoadFailed;
        const vocab = llama_model_get_vocab(model);

        return ModelHandle{
            .model = model,
            .vocab = vocab,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModelHandle) void {
        llama_free_model(self.model);
    }

    pub fn countTokensExact(self: *ModelHandle, text: []const u8) usize {
        const n = countTokens(self.vocab, text);
        if (n <= 0) return 0;
        return @intCast(n);
    }

    pub fn tokenizeText(self: *ModelHandle, allocator: std.mem.Allocator, text: []const u8) ![]Token {
        return tokenize(allocator, self.vocab, text, false);
    }

    pub fn getChatTemplate(self: *ModelHandle) ?[*:0]const u8 {
        return llama_model_chat_template(self.model, null);
    }

    pub fn applyChatTemplate(
        self: *ModelHandle,
        allocator: std.mem.Allocator,
        messages: []const ChatMessage,
        add_assistant: bool,
    ) ![]const u8 {
        const tmpl = llama_model_chat_template(self.model, null);

        const max_len: usize = @intCast(llama_chat_apply_template(
            tmpl,
            messages.ptr,
            messages.len,
            add_assistant,
            null,
            0,
        ));

        if (max_len < 0) return error.ChatTemplateFailed;

        const buf = try allocator.alloc(u8, @intCast(max_len));
        errdefer allocator.free(buf);

        const result = llama_chat_apply_template(
            tmpl,
            messages.ptr,
            messages.len,
            add_assistant,
            buf.ptr,
            @intCast(buf.len),
        );

        if (result < 0 or result > max_len) {
            allocator.free(buf);
            return error.ChatTemplateFailed;
        }

        return buf[0..@as(usize, @intCast(result))];
    }
};

pub const ContextHandle = struct {
    ctx: *Context,
    model: *ModelHandle,

    pub fn init(model: *ModelHandle, n_ctx: u32, n_threads: u32, n_batch: u32, flash_attn: bool) !ContextHandle {
        var params = llama_context_default_params();
        params.n_ctx = n_ctx;
        params.n_batch = n_batch;
        params.n_ubatch = @min(n_batch, 2048); // ubatch should not exceed 2048 for most GPUs
        params.n_seq_max = 1;
        params.n_threads = @intCast(n_threads);
        params.n_threads_batch = @intCast(n_threads);
        params.flash_attn_type = if (flash_attn) 1 else 0;

        const ctx = llama_init_from_model(model.model, params) orelse return error.ContextCreateFailed;
        return ContextHandle{
            .ctx = ctx,
            .model = model,
        };
    }

    pub fn deinit(self: *ContextHandle) void {
        llama_free(self.ctx);
    }
};
