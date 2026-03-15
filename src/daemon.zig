const std = @import("std");
const protocol = @import("protocol.zig");
const llama = @import("llama_api.zig");
const think_filter = @import("think_filter.zig");
const inference = @import("inference.zig");
const posix = std.posix;

const log = std.log.scoped(.daemon);

const DEFAULT_SYSTEM_PROMPT = "You recive user instructions in <instructions> and optional input in <input> tag. Apply the user instructions literaly or say that you cannot do it." ++
"Your audience is a large language model - LLM. Do not tailor answers for human. " ++
"Provide short terse responses in about 100 words, unless you are specifically asked for more details.";

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

const Config = struct {
    model_path: []const u8,
    context_size: u32,
    n_threads: u32,
    n_gpu_layers: i32,
    main_gpu: i32,
    n_batch: u32,
    flash_attn: bool,
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
    var n_gpu_layers: i32 = -1; // -1 means all layers on GPU
    var main_gpu: i32 = 0; // Default to first GPU (discrete GPU), set to -1 to use all GPUs
    var n_batch: u32 = 2048; // Increased default for better throughput
    var flash_attn: bool = true; // Enable flash attention by default for performance

    errdefer {
        if (model_path) |m| allocator.free(m);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var parts = std.mem.splitScalar(u8, trimmed, '=');
        const key = std.mem.trim(u8, parts.next() orelse continue, " \t");
        const value = std.mem.trim(u8, parts.rest(), " \t");
        if (value.len == 0) continue;

        if (std.mem.eql(u8, key, "model")) {
            if (model_path) |old| allocator.free(old);
            model_path = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "context_size")) {
            context_size = std.fmt.parseInt(u32, value, 10) catch context_size;
        } else if (std.mem.eql(u8, key, "n_threads")) {
            n_threads = std.fmt.parseInt(u32, value, 10) catch n_threads;
        } else if (std.mem.eql(u8, key, "n_gpu_layers")) {
            n_gpu_layers = std.fmt.parseInt(i32, value, 10) catch n_gpu_layers;
        } else if (std.mem.eql(u8, key, "main_gpu")) {
            main_gpu = std.fmt.parseInt(i32, value, 10) catch main_gpu;
        } else if (std.mem.eql(u8, key, "n_batch")) {
            n_batch = std.fmt.parseInt(u32, value, 10) catch n_batch;
        } else if (std.mem.eql(u8, key, "flash_attn")) {
            flash_attn = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes");
        }
    }

    return Config{
        .model_path = model_path orelse return error.MissingModelConfig,
        .context_size = context_size,
        .n_threads = n_threads,
        .n_gpu_layers = n_gpu_layers,
        .main_gpu = main_gpu,
        .n_batch = n_batch,
        .flash_attn = flash_attn,
        .allocator = allocator,
    };
}

pub const Daemon = struct {
    config: Config,
    model: llama.ModelHandle,
    ctx: llama.ContextHandle,
    socket_path: []const u8,
    pid_path: []const u8,
    pid_fd: ?posix.fd_t,
    allocator: std.mem.Allocator,
    chat_template: ?[*:0]const u8,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Daemon {
        log.info("Loading model from {s}", .{config.model_path});

        var model_params = llama.llama_model_default_params();
        model_params.n_gpu_layers = config.n_gpu_layers;
        model_params.split_mode = 0; // Use single GPU mode (LLAMA_SPLIT_MODE_NONE)
        model_params.main_gpu = config.main_gpu; // Which GPU to use (0 = first discrete GPU)
        log.info("Model params: n_gpu_layers={}, main_gpu={}, use_mmap={}", .{ model_params.n_gpu_layers, model_params.main_gpu, model_params.use_mmap });

        var model = try llama.ModelHandle.load(allocator, config.model_path, model_params);
        errdefer model.deinit();

        log.info("Model loaded, creating context...", .{});

        var ctx = try llama.ContextHandle.init(&model, config.context_size, config.n_threads, config.n_batch, config.flash_attn);
        errdefer ctx.deinit();

        log.info("Context created", .{});

        const chat_template = model.getChatTemplate();
        if (chat_template != null) {
            log.info("Chat template available", .{});
        } else {
            log.info("No chat template found, using raw prompts", .{});
        }

        const uid = posix.getuid();
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
            .pid_fd = null,
            .allocator = allocator,
            .chat_template = chat_template,
        };
    }

    pub fn deinit(self: *Daemon) void {
        if (self.pid_fd) |fd| {
            posix.close(fd);
        }
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

        // Acquire PID file lock to prevent multiple daemons
        const pid_path_z = try self.allocator.dupeZ(u8, self.pid_path);
        defer self.allocator.free(pid_path_z);

        // Open without TRUNC — we must acquire the lock before clobbering
        const pid_fd = posix.open(pid_path_z, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
        }, 0o644) catch |err| {
            log.err("Failed to open PID file {s}: {}", .{ self.pid_path, err });
            return err;
        };
        self.pid_fd = pid_fd;

        posix.flock(pid_fd, posix.LOCK.EX | posix.LOCK.NB) catch |err| {
            if (err == error.WouldBlock) {
                log.err("Another daemon is already running (PID file locked: {s})", .{self.pid_path});
                return error.DaemonAlreadyRunning;
            }
            log.err("Failed to lock PID file: {}", .{err});
            return err;
        };

        // Lock acquired — now truncate and write our PID
        const pid_file = std.fs.File{ .handle = pid_fd };
        pid_file.setEndPos(0) catch {};
        pid_file.seekTo(0) catch {};
        const pid = std.os.linux.getpid();
        var pid_buf: [20]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}\n", .{pid}) catch unreachable;
        pid_file.writeAll(pid_str) catch |err| {
            log.err("Failed to write PID file: {}", .{err});
            return err;
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
        std.posix.unlink(pid_path_z) catch {};
    }

    fn handleClient(self: *Daemon, client_socket: std.posix.fd_t) !void {
        const file = std.fs.File{ .handle = client_socket };

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

        // Create token buffer for batching writes
        var token_buffer = protocol.TokenBuffer.init(file);

        // Create inference engine
        var engine = inference.InferenceEngine.init(self.allocator, &self.model, &self.ctx, DEFAULT_SYSTEM_PROMPT);

        // Setup callback context for writing to token buffer
        var callback_ctx = TokenBufferCallbackContext{
            .token_buffer = &token_buffer,
            .last_flush_ms = std.time.milliTimestamp(),
        };

        const options = inference.InferenceOptions{
            .max_tokens = request.max_tokens,
        };

        // Run inference
        const stats = try engine.generate(
            request.prompt,
            request.stdin,
            options,
            tokenBufferCallback,
            &callback_ctx,
        );

        log.info("Generation complete: {d} tokens in {d}ms ({d:.2} tok/s)", .{
            stats.generated_tokens,
            stats.elapsed_ms,
            stats.tokens_per_second,
        });

        try token_buffer.flush();
        try token_buffer.writeEndMarker();
    }
};

/// Context for token buffer callback
const TokenBufferCallbackContext = struct {
    token_buffer: *protocol.TokenBuffer,
    last_flush_ms: i64,
};

/// Callback that writes tokens to buffered output with periodic flushing
fn tokenBufferCallback(chunk: []const u8, userdata: ?*anyopaque) bool {
    const ctx = @as(*TokenBufferCallbackContext, @ptrCast(@alignCast(userdata.?)));

    // Write token to buffer
    _ = ctx.token_buffer.writeToken(chunk) catch |err| {
        log.err("Failed to write token: {}", .{err});
        return false; // Stop generation on error
    };

    // Flush every 100ms for fluid streaming
    const now = std.time.milliTimestamp();
    if (now - ctx.last_flush_ms >= 100) {
        ctx.token_buffer.flush() catch |err| {
            log.err("Failed to flush token buffer: {}", .{err});
            return false;
        };
        ctx.last_flush_ms = now;
    }

    return true; // Continue generation
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load dynamic backends from the distribution lib directory
    // With GGML_BACKEND_DL, backends are loaded at runtime from .so files
    // First try path relative to executable, then fall back to dev path

    // Get the directory where this binary is located
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;

    var lib_path_allocated: ?[:0]u8 = null;
    defer if (lib_path_allocated) |p| allocator.free(p);

    const lib_path: [*:0]const u8 = if (std.fs.selfExeDirPath(&exe_dir_buf)) |exe_dir| blk: {
        const joined = std.fs.path.joinZ(allocator, &[_][]const u8{ exe_dir, "lib" }) catch |err| {
            log.warn("Could not construct lib path: {s}", .{@errorName(err)});
            break :blk "/home/m1ch4ls/play/token-saver/llama.cpp/build/bin";
        };
        lib_path_allocated = joined;
        break :blk joined;
    } else |err| blk: {
        log.warn("Could not determine executable directory: {s}", .{@errorName(err)});
        break :blk "/home/m1ch4ls/play/token-saver/llama.cpp/build/bin";
    };

    const backend_paths = &[_][*:0]const u8{
        lib_path, // Distribution: backends in lib/ subdirectory relative to binary
        "/home/m1ch4ls/play/token-saver/llama.cpp/build/bin", // Development
    };

    for (backend_paths) |path| {
        log.info("Loading dynamic backends from: {s}", .{path});
        llama.ggml_backend_load_all_from_path(path);
    }

    // Now initialize llama (after backends are loaded)
    llama.llama_backend_init();
    defer llama.llama_backend_free();

    setupSignalHandlers();

    var config = try readConfig(allocator);
    defer config.deinit();

    var daemon = try Daemon.init(allocator, config);
    defer daemon.deinit();

    try daemon.run();
}
