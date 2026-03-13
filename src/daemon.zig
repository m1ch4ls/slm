const std = @import("std");
const protocol = @import("protocol.zig");
const llama = @import("llama_api.zig");
const posix = std.posix;
const linux = std.os.linux;

const log = std.log.scoped(.daemon);

var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .monotonic);
}

pub fn setupSignalHandlers() void {
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &sa, null);
    posix.sigaction(posix.SIG.INT, &sa, null);
}

pub const Config = struct {
    model_path: []const u8,
    context_size: u32,
    n_threads: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.model_path);
    }
};

pub fn readConfig(allocator: std.mem.Allocator) !Config {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
        log.err("Could not get HOME environment variable: {}", .{err});
        return err;
    };
    defer allocator.free(home);

    const config_path = try std.fs.path.join(allocator, &.{ home, ".config", "slm", "config" });
    defer allocator.free(config_path);

    const content = std.fs.cwd().readFileAlloc(allocator, config_path, 4096) catch |err| {
        log.err("Could not read config file at {s}: {}", .{ config_path, err });
        log.err("Create it with: mkdir -p ~/.config/slm && echo 'model=/path/to/model.gguf' > ~/.config/slm/config", .{});
        return err;
    };
    defer allocator.free(content);

    var model_path: ?[]const u8 = null;
    var context_size: u32 = 32768;
    var n_threads: u32 = 4;

    errdefer {
        if (model_path) |m| allocator.free(m);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var parts = std.mem.splitScalar(u8, trimmed, '=');
        const key = std.mem.trim(u8, parts.next() orelse continue, " \t");
        const value = std.mem.trim(u8, parts.next() orelse continue, " \t");

        if (std.mem.eql(u8, key, "model")) {
            model_path = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "context_size")) {
            context_size = std.fmt.parseInt(u32, value, 10) catch context_size;
        } else if (std.mem.eql(u8, key, "n_threads")) {
            n_threads = std.fmt.parseInt(u32, value, 10) catch n_threads;
        }
    }

    return Config{
        .model_path = model_path orelse return error.MissingModelConfig,
        .context_size = context_size,
        .n_threads = n_threads,
        .allocator = allocator,
    };
}

pub const Daemon = struct {
    config: Config,
    model: llama.ModelHandle,
    ctx: llama.ContextHandle,
    socket_path: []const u8,
    pid_path: []const u8,
    allocator: std.mem.Allocator,
    chat_template: ?[*:0]const u8,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Daemon {
        log.info("Loading model from {s}", .{config.model_path});

        const model_params = llama.llama_model_default_params();
        log.info("Model params: n_gpu_layers={}, use_mmap={}", .{ model_params.n_gpu_layers, model_params.use_mmap });

        var model = try llama.ModelHandle.load(allocator, config.model_path, model_params);
        errdefer model.deinit();

        log.info("Model loaded, creating context...", .{});

        var ctx = try llama.ContextHandle.init(&model, config.context_size, config.n_threads);
        errdefer ctx.deinit();

        log.info("Context created", .{});

        const chat_template = model.getChatTemplate();
        if (chat_template != null) {
            log.info("Chat template available", .{});
        } else {
            log.info("No chat template found, using raw prompts", .{});
        }

        const uid = std.os.linux.getuid();
        const socket_path = try std.fmt.allocPrint(allocator, "/run/user/{d}/slm/daemon.sock", .{uid});
        errdefer allocator.free(socket_path);

        const pid_path = try std.fmt.allocPrint(allocator, "/run/user/{d}/slm/daemon.pid", .{uid});
        errdefer allocator.free(pid_path);

        log.info("Model loaded successfully", .{});

        return Daemon{
            .config = config,
            .model = model,
            .ctx = ctx,
            .socket_path = socket_path,
            .pid_path = pid_path,
            .allocator = allocator,
            .chat_template = chat_template,
        };
    }

    pub fn deinit(self: *Daemon) void {
        self.ctx.deinit();
        self.model.deinit();
        self.allocator.free(self.socket_path);
        self.allocator.free(self.pid_path);
    }

    pub fn run(self: *Daemon) !void {
        const dir_path = self.socket_path[0 .. std.mem.lastIndexOfScalar(u8, self.socket_path, '/') orelse 0];
        log.info("Creating socket directory: {s}", .{dir_path});
        std.fs.makeDirAbsolute(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                log.err("Failed to create socket directory: {}", .{err});
            }
        };

        log.info("Creating null-terminated socket path", .{});
        const socket_path_z = try self.allocator.dupeZ(u8, self.socket_path);
        defer self.allocator.free(socket_path_z);

        log.info("Unlinking existing socket", .{});
        std.posix.unlink(socket_path_z) catch {};

        log.info("Creating Unix socket", .{});
        const socket = try std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
            0,
        );
        defer std.posix.close(socket);

        log.info("Binding socket to {s}", .{self.socket_path});

        var addr: std.posix.sockaddr.un = std.mem.zeroes(std.posix.sockaddr.un);
        addr.family = std.posix.AF.UNIX;
        const path_len = @min(self.socket_path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], self.socket_path[0..path_len]);
        addr.path[path_len] = 0;

        const addr_ptr: *const std.posix.sockaddr = @ptrCast(&addr);
        const addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.un);
        std.posix.bind(socket, addr_ptr, addr_len) catch |err| {
            log.err("Bind failed: {}", .{err});
            return err;
        };
        log.info("Socket bound successfully", .{});
        try std.posix.listen(socket, 1);

        log.info("Daemon listening on {s}", .{self.socket_path});

        while (!shutdown_requested.load(.monotonic)) {
            var pollfd: [1]posix.pollfd = .{.{ .fd = socket, .events = posix.POLL.IN, .revents = 0 }};
            const poll_result = posix.poll(&pollfd, 100) catch |err| {
                log.err("Poll failed: {}", .{err});
                continue;
            };

            if (poll_result == 0) continue;

            log.debug("Waiting for connection...", .{});

            var client_addr: std.posix.sockaddr.un = undefined;
            var client_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.un);
            const client_socket = std.posix.accept(
                socket,
                @ptrCast(&client_addr),
                &client_addr_len,
                0,
            ) catch |err| {
                if (err == error.WouldBlock) continue;
                log.err("Accept failed: {}", .{err});
                continue;
            };

            log.info("Client connected", .{});
            self.handleClient(client_socket) catch |err| {
                log.err("Client error: {}", .{err});
            };
            std.posix.close(client_socket);
        }

        log.info("Shutting down daemon", .{});
        std.posix.unlink(socket_path_z) catch {};
    }

    fn handleClient(self: *Daemon, client_socket: std.posix.fd_t) !void {
        const file = std.fs.File{ .handle = client_socket };

        const memory = llama.llama_get_memory(self.ctx.ctx);
        if (memory) |mem| {
            llama.llama_memory_clear(mem);
        }

        const request = try protocol.readRequest(file, self.allocator);
        defer {
            self.allocator.free(request.prompt);
            self.allocator.free(request.stdin);
        }

        log.debug("Request: prompt={d} bytes, stdin={d} bytes, max_tokens={d}", .{
            request.prompt.len,
            request.stdin.len,
            request.max_tokens,
        });

        const formatted_prompt = if (self.chat_template != null) blk: {
            const user_content = if (request.stdin.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ request.prompt, request.stdin })
            else
                try self.allocator.dupe(u8, request.prompt);
            defer self.allocator.free(user_content);

            const user_content_z = try self.allocator.dupeZ(u8, user_content);
            defer self.allocator.free(user_content_z);

            const role_z = "user";
            const messages = [_]llama.ChatMessage{
                .{ .role = role_z.ptr, .content = user_content_z.ptr },
            };

            const result = try self.model.applyChatTemplate(
                self.allocator,
                &messages,
                true,
            );
            break :blk result;
        } else blk: {
            const full_prompt = try std.fmt.allocPrint(
                self.allocator,
                "{s}\n\n{s}",
                .{ request.prompt, request.stdin },
            );
            break :blk full_prompt;
        };
        defer self.allocator.free(formatted_prompt);

        log.debug("Formatted prompt ({d} bytes): {s}", .{ formatted_prompt.len, formatted_prompt[0..@min(200, formatted_prompt.len)] });

        const add_bos = llama.llama_vocab_get_add_bos(self.model.vocab);
        const tokens = try llama.tokenize(self.allocator, self.model.vocab, formatted_prompt, add_bos);
        defer self.allocator.free(tokens);

        log.debug("Tokenized to {d} tokens (add_bos={})", .{ tokens.len, add_bos });

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
            return error.DecodeFailed;
        }

        const sampler = llama.llama_sampler_init_greedy();
        defer llama.llama_sampler_free(sampler);

        var generated_tokens: u32 = 0;
        var pos: i32 = @intCast(tokens.len);

        while (generated_tokens < request.max_tokens) : (generated_tokens += 1) {
            const new_token = llama.llama_sampler_sample(sampler, self.ctx.ctx, -1);

            if (new_token == llama.TokenNull or llama.llama_vocab_is_eog(self.model.vocab, new_token)) {
                log.debug("EOS token detected, stopping", .{});
                break;
            }

            const token_text = try llama.detokenize(self.allocator, self.model.vocab, new_token);
            defer self.allocator.free(token_text);

            try protocol.writeToken(file, token_text);

            var new_batch = llama.llama_batch_init(1, 0, 1);
            defer llama.llama_batch_free(new_batch);

            new_batch.token[0] = new_token;
            new_batch.pos[0] = pos;
            new_batch.n_seq_id[0] = 1;
            new_batch.seq_id[0][0] = 0;
            if (new_batch.logits) |logits| {
                logits[0] = 1;
            }
            new_batch.n_tokens = 1;

            _ = llama.llama_decode(self.ctx.ctx, new_batch);
            pos += 1;
        }

        try protocol.writeEndMarker(file);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    llama.llama_backend_init();
    defer llama.llama_backend_free();

    setupSignalHandlers();

    var config = try readConfig(allocator);
    defer config.deinit();

    var daemon = try Daemon.init(allocator, config);
    defer daemon.deinit();

    try daemon.run();
}
