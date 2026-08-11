const std = @import("std");
const model = @import("model.zig");
const source_input = @import("source_input.zig");

pub const ResolveOptions = struct {
    state_dir: ?[]const u8 = null,
    xdg_state_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
};

pub const RequestContext = struct {
    task_instruction: []const u8,
    runtime_system_prompt: []const u8,
    model_id: []const u8,
    max_tokens: u32,
};

pub const Durations = struct {
    source_ingestion: u64,
    model_request: u64,
    total: u64,
};

const FailureFacts = struct {
    kind: []const u8,
    http_status: ?u16 = null,
    error_name: ?[]const u8 = null,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []u8,
    root: std.Io.Dir,
    staging: std.Io.Dir,
    attempts: std.Io.Dir,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, options: ResolveOptions) !Store {
        const root_path = try resolveRoot(allocator, options);
        errdefer allocator.free(root_path);

        const parent_path = std.fs.path.dirname(root_path) orelse return error.InvalidStateDirectory;
        try std.Io.Dir.cwd().createDirPath(io, parent_path);
        try makeOwnerOnlyDir(std.Io.Dir.cwd(), io, root_path);

        const root = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .follow_symlinks = false });
        errdefer root.close(io);
        try requireOwnerOnly(root, io);

        try makeOwnerOnlyDir(root, io, ".staging");
        try makeOwnerOnlyDir(root, io, "attempts");

        const staging = try root.openDir(io, ".staging", .{ .follow_symlinks = false });
        errdefer staging.close(io);
        try requireOwnerOnly(staging, io);

        const attempts = try root.openDir(io, "attempts", .{ .follow_symlinks = false });
        errdefer attempts.close(io);
        try requireOwnerOnly(attempts, io);

        return .{
            .allocator = allocator,
            .io = io,
            .root_path = root_path,
            .root = root,
            .staging = staging,
            .attempts = attempts,
        };
    }

    pub fn close(self: *Store) void {
        self.attempts.close(self.io);
        self.staging.close(self.io);
        self.root.close(self.io);
        self.allocator.free(self.root_path);
    }

    pub fn begin(self: *Store, context: RequestContext, started_at_utc: []const u8) !Attempt {
        const id = try self.allocateId();
        const id_text = try std.fmt.allocPrint(self.allocator, "{d}", .{id});
        errdefer self.allocator.free(id_text);

        try makeOwnerOnlyDir(self.staging, self.io, id_text);
        errdefer self.staging.deleteTree(self.io, id_text) catch {};
        const dir = try self.staging.openDir(self.io, id_text, .{ .follow_symlinks = false });
        errdefer dir.close(self.io);

        return .{
            .store = self,
            .id = id,
            .id_text = id_text,
            .dir = dir,
            .context = context,
            .started_at_utc = started_at_utc,
        };
    }

    fn allocateId(self: *Store) !u64 {
        var next: u64 = 1;
        if (self.root.openFile(self.io, ".next-id", .{})) |file| {
            defer file.close(self.io);
            var buffer: [32]u8 = undefined;
            const length = try file.readPositionalAll(self.io, &buffer, 0);
            next = try std.fmt.parseInt(u64, std.mem.trim(u8, buffer[0..length], "\r\n "), 10);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const file = try self.root.createFile(self.io, ".next-id", .{
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer file.close(self.io);
        var buffer: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d}\n", .{try std.math.add(u64, next, 1)});
        try file.writeStreamingAll(self.io, text);
        return next;
    }
};

pub const Attempt = struct {
    store: *Store,
    id: u64,
    id_text: []u8,
    dir: std.Io.Dir,
    context: RequestContext,
    started_at_utc: []const u8,
    source_byte_count: ?u64 = null,
    source_utf8_valid: ?bool = null,
    dir_open: bool = true,
    finalized: bool = false,

    pub fn captureSource(self: *Attempt, reader: *std.Io.Reader) !source_input.Capture {
        const file = try self.dir.createFile(self.store.io, "source-input.gz", .{
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer file.close(self.store.io);

        var file_buffer: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(self.store.io, &file_buffer);
        var compression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var gzip = try std.compress.flate.Compress.init(
            &file_writer.interface,
            &compression_buffer,
            .gzip,
            .level_1,
        );
        var captured = try source_input.capture(self.store.allocator, reader, .{
            .processing_byte_limit = model.processing_byte_limit,
            .drain_oversized = true,
            .sink = &gzip.writer,
        });
        errdefer captured.deinit(self.store.allocator);
        try gzip.finish();
        try file_writer.interface.flush();

        self.source_byte_count = captured.byte_count;
        self.source_utf8_valid = captured.utf8_valid;
        return captured;
    }

    pub fn finalizeCompleted(
        self: *Attempt,
        completion: model.Completion,
        durations: Durations,
    ) !void {
        const output = completion.output.bytes();
        try writeGzip(self.dir, self.store.io, "model-output.gz", output);

        const usage: ?model.Usage = if (completion.usage.isPresent()) completion.usage else null;
        try self.finalize(.{
            .kind = "completed",
            .model_output = .{
                .kind = completion.output.kind(),
                .byte_count = output.len,
                .finish_reason = completion.finish_reason,
                .usage = usage,
            },
        }, durations);
    }

    pub fn finalizeRequestFailed(
        self: *Attempt,
        failure: model.RequestFailure,
        durations: Durations,
    ) !void {
        const facts: FailureFacts = switch (failure) {
            .network => |error_name| .{ .kind = "network", .error_name = error_name },
            .http_status => |status| .{ .kind = "http_status", .http_status = status },
        };
        try self.finalize(.{
            .kind = "model_request_failed",
            .failure = facts,
        }, durations);
    }

    pub fn finalizeResponseInvalid(
        self: *Attempt,
        reason: model.ResponseInvalidReason,
        durations: Durations,
    ) !void {
        try self.finalize(.{
            .kind = "model_response_invalid",
            .reason = @tagName(reason),
        }, durations);
    }

    pub fn finalizeSourceInputTooLarge(self: *Attempt, durations: Durations) !void {
        try self.finalize(.{ .kind = "source_input_too_large" }, durations);
    }

    pub fn finalizeSourceInputInvalid(self: *Attempt, durations: Durations) !void {
        try self.finalize(.{ .kind = "source_input_invalid" }, durations);
    }

    pub fn attemptId(self: Attempt) u64 {
        return self.id;
    }

    fn finalize(self: *Attempt, outcome: anytype, durations: Durations) !void {
        const source_byte_count = self.source_byte_count orelse return error.SourceNotCaptured;
        const source_utf8_valid = self.source_utf8_valid orelse return error.SourceNotCaptured;
        const metadata = .{
            .schema_version = model.schema_version,
            .request_format_version = model.request_format_version,
            .attempt_id = self.id,
            .started_at_utc = self.started_at_utc,
            .durations_ns = durations,
            .request = .{
                .task_instruction = self.context.task_instruction,
                .runtime_system_prompt = self.context.runtime_system_prompt,
                .model_id = self.context.model_id,
                .max_tokens = self.context.max_tokens,
                .processing_byte_limit = model.processing_byte_limit,
            },
            .source_input = .{
                .byte_count = source_byte_count,
                .utf8_valid = source_utf8_valid,
            },
            .outcome = outcome,
        };
        const json = try std.json.Stringify.valueAlloc(self.store.allocator, metadata, .{
            .emit_null_optional_fields = false,
        });
        defer self.store.allocator.free(json);

        const metadata_file = try self.dir.createFile(self.store.io, "metadata.json", .{
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer metadata_file.close(self.store.io);
        try metadata_file.writeStreamingAll(self.store.io, json);

        self.dir.close(self.store.io);
        self.dir_open = false;
        try self.store.staging.rename(self.id_text, self.store.attempts, self.id_text, self.store.io);
        self.finalized = true;
    }

    pub fn deinit(self: *Attempt) void {
        if (!self.finalized) {
            if (self.dir_open) self.dir.close(self.store.io);
            self.store.staging.deleteTree(self.store.io, self.id_text) catch {};
        }
        self.store.allocator.free(self.id_text);
    }
};

pub fn resolveRoot(allocator: std.mem.Allocator, options: ResolveOptions) ![]u8 {
    if (options.state_dir) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.RelativeStateDirectory;
        return allocator.dupe(u8, path);
    }
    if (options.xdg_state_home) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidStateDirectory;
        return std.fs.path.join(allocator, &.{ path, "slm" });
    }
    if (options.home) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidStateDirectory;
        return std.fs.path.join(allocator, &.{ path, ".local", "state", "slm" });
    }
    return error.MissingStateDirectory;
}

fn makeOwnerOnlyDir(parent: std.Io.Dir, io: std.Io, name: []const u8) !void {
    parent.createDir(io, name, std.Io.File.Permissions.fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn requireOwnerOnly(dir: std.Io.Dir, io: std.Io) !void {
    const stat = try dir.stat(io);
    if (stat.permissions.toMode() & 0o077 != 0) return error.UnsafeStateDirectoryPermissions;
}

fn writeGzip(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(io, name, .{
        .exclusive = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer file.close(io);

    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    var compression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip = try std.compress.flate.Compress.init(
        &file_writer.interface,
        &compression_buffer,
        .gzip,
        .level_1,
    );
    try gzip.writer.writeAll(bytes);
    try gzip.finish();
    try file_writer.interface.flush();
}

test "resolveRoot follows override, XDG, and home precedence" {
    const allocator = std.testing.allocator;

    const overridden = try resolveRoot(allocator, .{
        .state_dir = "/override",
        .xdg_state_home = "/xdg",
        .home = "/home/person",
    });
    defer allocator.free(overridden);
    try std.testing.expectEqualStrings("/override", overridden);

    const xdg = try resolveRoot(allocator, .{ .xdg_state_home = "/xdg" });
    defer allocator.free(xdg);
    try std.testing.expectEqualStrings("/xdg/slm", xdg);

    const home = try resolveRoot(allocator, .{ .home = "/home/person" });
    defer allocator.free(home);
    try std.testing.expectEqualStrings("/home/person/.local/state/slm", home);

    try std.testing.expectError(
        error.RelativeStateDirectory,
        resolveRoot(allocator, .{ .state_dir = "relative" }),
    );
}

test "completed attempts publish structured metadata and exact gzip payloads" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(io, &path_buffer);
    const root_path = try std.fs.path.join(allocator, &.{ path_buffer[0..path_length], "store" });
    defer allocator.free(root_path);

    var store = try Store.open(allocator, io, .{ .state_dir = root_path });
    defer store.close();

    const context: RequestContext = .{
        .task_instruction = "summarize exactly",
        .runtime_system_prompt = "system rules\n",
        .model_id = "test-model",
        .max_tokens = 321,
    };
    const source = "first line\nsecond line\x00";
    var completion: model.Completion = .{
        .output = .{ .refusal = try allocator.dupe(u8, "not allowed") },
        .finish_reason = try allocator.dupe(u8, "stop"),
        .usage = .{ .prompt_tokens = 8, .total_tokens = 11 },
    };
    defer completion.deinit(allocator);

    var attempt = try store.begin(context, "2026-08-11T12:34:56.789Z");
    defer attempt.deinit();
    var source_reader: std.Io.Reader = .fixed(source);
    var captured = try attempt.captureSource(&source_reader);
    defer captured.deinit(allocator);
    try attempt.finalizeCompleted(completion, .{
        .source_ingestion = 10,
        .model_request = 20,
        .total = 30,
    });

    const metadata_bytes = try store.attempts.readFileAlloc(
        io,
        "1/metadata.json",
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(metadata_bytes);

    const Metadata = struct {
        schema_version: u32,
        request_format_version: u32,
        attempt_id: u64,
        started_at_utc: []const u8,
        durations_ns: Durations,
        request: struct {
            task_instruction: []const u8,
            runtime_system_prompt: []const u8,
            model_id: []const u8,
            max_tokens: u32,
            processing_byte_limit: u64,
        },
        source_input: struct {
            byte_count: u64,
            utf8_valid: bool,
        },
        outcome: struct {
            kind: []const u8,
            model_output: struct {
                kind: []const u8,
                byte_count: u64,
                finish_reason: ?[]const u8 = null,
                usage: ?model.Usage = null,
            },
        },
    };
    var parsed = try std.json.parseFromSlice(Metadata, allocator, metadata_bytes, .{});
    defer parsed.deinit();
    const metadata = parsed.value;

    try std.testing.expectEqual(model.schema_version, metadata.schema_version);
    try std.testing.expectEqual(model.request_format_version, metadata.request_format_version);
    try std.testing.expectEqual(@as(u64, 1), metadata.attempt_id);
    try std.testing.expectEqualStrings("2026-08-11T12:34:56.789Z", metadata.started_at_utc);
    try std.testing.expectEqual(@as(u64, 10), metadata.durations_ns.source_ingestion);
    try std.testing.expectEqual(@as(u64, 20), metadata.durations_ns.model_request);
    try std.testing.expectEqual(@as(u64, 30), metadata.durations_ns.total);
    try std.testing.expectEqualStrings(context.task_instruction, metadata.request.task_instruction);
    try std.testing.expectEqualStrings(context.runtime_system_prompt, metadata.request.runtime_system_prompt);
    try std.testing.expectEqualStrings(context.model_id, metadata.request.model_id);
    try std.testing.expectEqual(context.max_tokens, metadata.request.max_tokens);
    try std.testing.expectEqual(model.processing_byte_limit, metadata.request.processing_byte_limit);
    try std.testing.expectEqual(@as(u64, source.len), metadata.source_input.byte_count);
    try std.testing.expect(metadata.source_input.utf8_valid);
    try std.testing.expectEqualStrings("completed", metadata.outcome.kind);
    try std.testing.expectEqualStrings("refusal", metadata.outcome.model_output.kind);
    try std.testing.expectEqual(@as(u64, "not allowed".len), metadata.outcome.model_output.byte_count);
    try std.testing.expectEqualStrings("stop", metadata.outcome.model_output.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 8), metadata.outcome.model_output.usage.?.prompt_tokens);
    try std.testing.expectEqual(@as(?u64, null), metadata.outcome.model_output.usage.?.completion_tokens);
    try std.testing.expectEqual(@as(?u64, 11), metadata.outcome.model_output.usage.?.total_tokens);

    try expectGzipPayload(store.attempts, io, allocator, "1/source-input.gz", source);
    try expectGzipPayload(store.attempts, io, allocator, "1/model-output.gz", "not allowed");
}

test "store creates owner-only paths and rejects an unsafe existing root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(io, &path_buffer);
    const secure_path = try std.fs.path.join(allocator, &.{ path_buffer[0..path_length], "secure" });
    defer allocator.free(secure_path);

    var store = try Store.open(allocator, io, .{ .state_dir = secure_path });
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0),
        (try store.root.stat(io)).permissions.toMode() & 0o077,
    );
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0),
        (try store.staging.stat(io)).permissions.toMode() & 0o077,
    );
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0),
        (try store.attempts.stat(io)).permissions.toMode() & 0o077,
    );
    store.close();

    const unsafe_path = try std.fs.path.join(allocator, &.{ path_buffer[0..path_length], "unsafe" });
    defer allocator.free(unsafe_path);
    try std.Io.Dir.createDirAbsolute(
        io,
        unsafe_path,
        std.Io.File.Permissions.fromMode(0o755),
    );
    const unsafe = try std.Io.Dir.openFileAbsolute(io, unsafe_path, .{ .allow_directory = true });
    defer unsafe.close(io);
    try unsafe.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
    try std.testing.expectError(
        error.UnsafeStateDirectoryPermissions,
        Store.open(allocator, io, .{ .state_dir = unsafe_path }),
    );
}

test "failed Source input capture publishes no attempt" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(io, &path_buffer);
    const root_path = try std.fs.path.join(allocator, &.{ path_buffer[0..path_length], "store" });
    defer allocator.free(root_path);

    var store = try Store.open(allocator, io, .{ .state_dir = root_path });
    defer store.close();
    const context: RequestContext = .{
        .task_instruction = "process",
        .runtime_system_prompt = "rules",
        .model_id = "test-model",
        .max_tokens = 10,
    };

    var attempt = try store.begin(context, "2026-08-11T12:34:56.789Z");
    var failing_reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.ReadFailed, attempt.captureSource(&failing_reader));
    attempt.deinit();

    try std.testing.expectError(
        error.FileNotFound,
        store.attempts.openDir(io, "1", .{ .follow_symlinks = false }),
    );
}

fn expectGzipPayload(
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: []const u8,
) !void {
    const compressed = try dir.readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len >= 10);

    var compressed_reader: std.Io.Reader = .fixed(compressed);
    var decompression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip: std.compress.flate.Decompress = .init(
        &compressed_reader,
        .gzip,
        &decompression_buffer,
    );
    const decompressed = gzip.reader.allocRemaining(allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return gzip.err.?,
        else => |other| return other,
    };
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, expected, decompressed);
}
