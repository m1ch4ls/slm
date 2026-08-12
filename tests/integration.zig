const std = @import("std");
const options = @import("integration_options");

const allocator = std.testing.allocator;
const limit = 16 * 1024 * 1024;

const Result = struct { term: std.process.Child.Term, stdout: []u8, stderr: []u8 };

const Waiter = struct {
    child: *std.process.Child,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: ?std.process.Child.Term = null,

    fn wait(self: *Waiter) void {
        self.result = self.child.wait(std.testing.io) catch null;
        self.done.store(true, .release);
    }
};

fn waitForExit(child: *std.process.Child, timeout_ms: i64) !std.process.Child.Term {
    var waiter: Waiter = .{ .child = child };
    const thread = try std.Thread.spawn(.{}, Waiter.wait, .{&waiter});
    defer thread.join();
    const deadline = std.Io.Clock.awake.now(std.testing.io).addDuration(.fromMilliseconds(timeout_ms));
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline.nanoseconds) {
        if (waiter.done.load(.acquire)) return waiter.result orelse error.ProcessWaitFailed;
        try std.Io.sleep(std.testing.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake);
    }
    child.kill(std.testing.io);
    return error.ProcessTimedOut;
}

const Fixture = struct {
    server: std.Io.net.Server,
    thread: std.Thread,
    io: std.Io,
    mutex: std.atomic.Mutex = .unlocked,
    requests: usize = 0,
    mode: Mode,
    stopping: bool = false,
    stopped: bool = false,
    failure: ?anyerror = null,

    const Mode = enum { success, failures, processed, echo };

    fn start(mode: Mode) !*Fixture {
        const fixture = try allocator.create(Fixture);
        const io = std.testing.io;
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.* = .{
            .server = try address.listen(io, .{ .reuse_address = true }),
            .thread = undefined,
            .io = io,
            .mode = mode,
        };
        fixture.thread = try std.Thread.spawn(.{}, run, .{fixture});
        return fixture;
    }

    fn stop(self: *Fixture) !void {
        self.lock();
        if (self.stopped) {
            self.mutex.unlock();
            return;
        }
        self.stopped = true;
        self.stopping = true;
        self.mutex.unlock();
        var stream = self.server.socket.address.connect(self.io, .{ .mode = .stream }) catch unreachable;
        stream.close(self.io);
        self.thread.join();
        self.server.deinit(self.io);
        const failure = self.failure;
        if (failure) |err| return err;
    }

    fn port(self: *Fixture) u16 {
        return self.server.socket.address.getPort();
    }

    fn requestCount(self: *Fixture) usize {
        self.lock();
        defer self.mutex.unlock();
        return self.requests;
    }

    fn run(self: *Fixture) void {
        while (true) {
            var stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            self.lock();
            const stopping = self.stopping;
            self.mutex.unlock();
            if (stopping) return;
            self.serve(stream) catch |err| {
                self.lock();
                self.failure = err;
                self.mutex.unlock();
                return;
            };
        }
    }

    fn serve(self: *Fixture, stream: std.Io.net.Stream) !void {
        var read_buffer: [16 * 1024]u8 = undefined;
        var write_buffer: [16 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        var writer = stream.writer(self.io, &write_buffer);
        var http = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try http.receiveHead();
        const target_is_chat_completions = std.mem.eql(u8, request.head.target, "/v1/chat/completions");
        var accept_gzip = false;
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "accept-encoding") and std.mem.eql(u8, header.value, "gzip")) accept_gzip = true;
        }
        var body_buffer: [16 * 1024]u8 = undefined;
        const body_reader = request.readerExpectNone(&body_buffer);
        const request_body = try body_reader.allocRemaining(allocator, .limited(limit + 1024 * 1024));
        defer allocator.free(request_body);
        self.lock();
        self.requests += 1;
        const index = self.requests;
        self.mutex.unlock();

        if (self.mode == .success and index == 1) {
            if (!target_is_chat_completions) return error.WrongTarget;
            if (!accept_gzip) return error.MissingGzipEncoding;
            try expectContains(request_body, "\"model\":\"fixture-model\"");
            try expectContains(request_body, "\"max_tokens\":77");
            const body = "{\"ignored\":true,\"choices\":[{\"message\":{\"content\":\"recorded output\",\"refusal\":null},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":9,\"total_tokens\":12}}";
            const gzip = try gzipStored(body);
            defer allocator.free(gzip);
            try request.respond(gzip, .{ .extra_headers = &.{ .{ .name = "content-encoding", .value = "gzip" }, .{ .name = "content-type", .value = "application/json" } } });
            return;
        }
        const response: []const u8 = switch (self.mode) {
            .success => "{\"choices\":[{\"message\":{\"content\":null,\"refusal\":\"fixture refusal\"}}]}",
            .processed => "{\"choices\":[{\"message\":{\"content\":\"processed\"}}]}",
            .echo => return self.respondEcho(&request, request_body),
            .failures => switch (index) {
                1 => "{",
                2 => "{\"choices\":[]}",
                3 => "{\"choices\":[{\"message\":{}}]}",
                4 => "{\"choices\":[{\"message\":{\"content\":\"answer\",\"refusal\":\"no\"}}]}",
                5 => return self.respondLarge(&request),
                6 => return request.respond("secret provider body", .{ .status = .too_many_requests }),
                else => unreachable,
            },
        };
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }

    fn respondLarge(_: *Fixture, request: *std.http.Server.Request) !void {
        const response = try allocator.alloc(u8, limit + 1);
        defer allocator.free(response);
        @memset(response, 'x');
        try request.respond(response, .{});
    }

    fn respondEcho(_: *Fixture, request: *std.http.Server.Request, body: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const messages = parsed.value.object.get("messages") orelse return error.MissingMessages;
        const content = messages.array.items[1].object.get("content") orelse return error.MissingContent;
        const output = try std.fmt.allocPrint(allocator, "output:{s}", .{content.string});
        defer allocator.free(output);
        const response = try std.json.Stringify.valueAlloc(allocator, .{ .choices = .{.{ .message = .{ .content = output } }} }, .{});
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }

    fn lock(self: *Fixture) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

fn gzipStored(body: []const u8) ![]u8 {
    if (body.len > std.math.maxInt(u16)) return error.BodyTooLarge;
    const output = try allocator.alloc(u8, 10 + 5 + body.len + 8);
    @memcpy(output[0..10], &[_]u8{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3 });
    output[10] = 1;
    std.mem.writeInt(u16, output[11..13], @intCast(body.len), .little);
    std.mem.writeInt(u16, output[13..15], ~@as(u16, @intCast(body.len)), .little);
    @memcpy(output[15 .. 15 + body.len], body);
    std.mem.writeInt(u32, output[15 + body.len ..][0..4], std.hash.Crc32.hash(body), .little);
    std.mem.writeInt(u32, output[19 + body.len ..][0..4], @intCast(body.len), .little);
    return output;
}

fn invoke(args: []const []const u8, input: []const u8, environment: *const std.process.Environ.Map, stdout_behavior: std.process.SpawnOptions.StdIo) !Result {
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, args.len + 1);
    defer argv.deinit(allocator);
    try argv.append(allocator, options.slm_path);
    try argv.appendSlice(allocator, args);
    var child = try std.process.spawn(std.testing.io, .{
        .argv = argv.items,
        .environ_map = environment,
        .stdin = .pipe,
        .stdout = stdout_behavior,
        .stderr = .pipe,
    });
    try child.stdin.?.writeStreamingAll(std.testing.io, input);
    child.stdin.?.close(std.testing.io);
    child.stdin = null;
    if (stdout_behavior == .close) {
        var multi_buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(allocator, std.testing.io, multi_buffer.toStreams(), &.{child.stderr.?});
        defer multi_reader.deinit();
        while (multi_reader.fill(64, .none)) {} else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        try multi_reader.checkAnyError();
        const term = try child.wait(std.testing.io);
        return .{ .term = term, .stdout = try allocator.dupe(u8, ""), .stderr = try multi_reader.toOwnedSlice(0) };
    }
    var multi_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, std.testing.io, multi_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    while (multi_reader.fill(64, .none)) {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();
    const term = try child.wait(std.testing.io);
    const stdout = try multi_reader.toOwnedSlice(0);
    const stderr = try multi_reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

fn readFile(file: std.Io.File) ![]u8 {
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(std.testing.io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(32 * 1024 * 1024));
}

fn env(entries: []const struct { []const u8, []const u8 }) !std.process.Environ.Map {
    var result = std.process.Environ.Map.init(allocator);
    for (entries) |entry| try result.put(entry[0], entry[1]);
    return result;
}

fn expectExit(result: Result, code: u8) !void {
    try std.testing.expectEqual(std.process.Child.Term{ .exited = code }, result.term);
}
fn freeResult(result: Result) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}
fn path(parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}
fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}
fn expectMissing(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn stopFixture(fixture: *Fixture) void {
    fixture.stop() catch @panic("fixture assertion failed");
    allocator.destroy(fixture);
}

fn readGzip(file_path: []const u8) ![]u8 {
    const compressed = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, allocator, .unlimited);
    defer allocator.free(compressed);
    var input = std.Io.Reader.fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input, .gzip, &window);
    return decompressor.reader.allocRemaining(allocator, .unlimited);
}

fn metadata(state: []const u8, id: usize) ![]u8 {
    const id_text = try std.fmt.allocPrint(allocator, "{d}", .{id});
    defer allocator.free(id_text);
    const file_path = try path(&.{ state, "attempts", id_text, "metadata.json" });
    defer allocator.free(file_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, allocator, .limited(1024 * 1024));
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    return bytes;
}

fn recordPath(state: []const u8, id: usize, name: []const u8) ![]u8 {
    const id_text = try std.fmt.allocPrint(allocator, "{d}", .{id});
    defer allocator.free(id_text);
    return path(&.{ state, "attempts", id_text, name });
}

fn expectNoPath(file_path: []const u8) !void {
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, file_path, .{}));
}

fn expectFailureRecord(state: []const u8, id: usize, source: []const u8) ![]u8 {
    const record = try metadata(state, id);
    errdefer allocator.free(record);
    const source_path = try recordPath(state, id, "source-input.gz");
    defer allocator.free(source_path);
    const retained = try readGzip(source_path);
    defer allocator.free(retained);
    try std.testing.expectEqualSlices(u8, source, retained);
    const output_path = try recordPath(state, id, "model-output.gz");
    defer allocator.free(output_path);
    try expectNoPath(output_path);
    try expectContains(record, "\"task_instruction\":\"summarize\"");
    try expectContains(record, "\"model_id\":\"fixture-model\"");
    try expectContains(record, "\"max_tokens\":77");
    try expectContains(record, "\"utf8_valid\":true");
    return record;
}

fn expectUtcTimestamp(value: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 24), value.len);
    for ([_]usize{ 4, 7, 10, 13, 16, 19, 23 }) |index| {
        const expected: u8 = switch (index) {
            4, 7 => '-',
            10 => 'T',
            13, 16 => ':',
            19 => '.',
            23 => 'Z',
            else => unreachable,
        };
        try std.testing.expectEqual(expected, value[index]);
    }
    for (value, 0..) |byte, index| {
        if (index == 4 or index == 7 or index == 10 or index == 13 or index == 16 or index == 19 or index == 23) continue;
        try std.testing.expect(byte >= '0' and byte <= '9');
    }
}

fn expectMetadataInvariants(record: []const u8, id: usize) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, record, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("schema_version").?.integer);
    try std.testing.expectEqual(@as(i64, 1), root.get("request_format_version").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(id)), root.get("attempt_id").?.integer);
    try expectUtcTimestamp(root.get("started_at_utc").?.string);
    const durations = root.get("durations_ns").?.object;
    const source = durations.get("source_ingestion").?.integer;
    const model_request = durations.get("model_request").?.integer;
    const total = durations.get("total").?.integer;
    try std.testing.expect(source >= 0 and model_request >= 0 and total >= 0);
    try std.testing.expect(total >= source);
    try std.testing.expect(total >= model_request);
}

fn echoOutput(input: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "output:<instructions>process</instructions>\n\n<input>{s}</input>", .{input});
}

fn publicRecord(state: []const u8, id: usize, source: []const u8, output: ?[]const u8) !void {
    const directory_path = try recordPath(state, id, ".");
    defer allocator.free(directory_path);
    var directory = try std.Io.Dir.openDirAbsolute(std.testing.io, directory_path, .{ .iterate = true });
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    var metadata_seen = false;
    var source_seen = false;
    var output_seen = false;
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        count += 1;
        metadata_seen = metadata_seen or std.mem.eql(u8, entry.name, "metadata.json");
        source_seen = source_seen or std.mem.eql(u8, entry.name, "source-input.gz");
        output_seen = output_seen or std.mem.eql(u8, entry.name, "model-output.gz");
    }
    try std.testing.expectEqual(@as(usize, if (output == null) 2 else 3), count);
    try std.testing.expect(metadata_seen and source_seen and output_seen == (output != null));
    const record = try metadata(state, id);
    defer allocator.free(record);
    try expectMetadataInvariants(record, id);
    try expectContains(record, "\"task_instruction\":\"process\"");
    try expectContains(record, "\"runtime_system_prompt\":");
    try expectContains(record, "\"model_id\":\"fixture-model\"");
    try expectContains(record, "\"max_tokens\":16384");
    try expectContains(record, "\"processing_byte_limit\":16777216");
    const source_path = try recordPath(state, id, "source-input.gz");
    defer allocator.free(source_path);
    const stored_source = try readGzip(source_path);
    defer allocator.free(stored_source);
    try std.testing.expectEqualSlices(u8, source, stored_source);
    if (output) |expected_output| {
        const output_path = try recordPath(state, id, "model-output.gz");
        defer allocator.free(output_path);
        const stored_output = try readGzip(output_path);
        defer allocator.free(stored_output);
        try std.testing.expectEqualSlices(u8, expected_output, stored_output);
        const size_fact = try std.fmt.allocPrint(allocator, "\"byte_count\":{d}", .{expected_output.len});
        defer allocator.free(size_fact);
        try expectContains(record, size_fact);
    }
}

test "configuration integration" {
    var automatic = try env(&.{ .{ "OPENAI_API_KEY", "openai-secret" }, .{ "GEMINI_API_KEY", "gemini-secret" } });
    defer automatic.deinit();
    const a = try invoke(&.{"--debug-config"}, "", &automatic, .pipe);
    defer freeResult(a);
    try expectExit(a, 0);
    try expectContains(a.stdout, "mode: automatic\n");
    try expectContains(a.stdout, "provider: OpenAI\n");
    try expectContains(a.stdout, "model: gpt-5-nano\n");
    try expectContains(a.stdout, "authentication: OPENAI_API_KEY\n");
    try expectMissing(a.stdout, "openai-secret");
    var explicit = try env(&.{ .{ "SLM_BASE_URL", "http://localhost:11434/v1" }, .{ "SLM_MODEL", "local-model" }, .{ "SLM_API_KEY", "local-secret" } });
    defer explicit.deinit();
    const e = try invoke(&.{"--debug-config"}, "", &explicit, .pipe);
    defer freeResult(e);
    try expectExit(e, 0);
    try expectContains(e.stdout, "mode: explicit\n");
    try expectContains(e.stdout, "provider: unknown\n");
    try expectMissing(e.stdout, "local-secret");
    var invalid = try env(&.{.{ "GEMINI_API_KEY", "" }});
    defer invalid.deinit();
    const i = try invoke(&.{"--debug-config"}, "", &invalid, .pipe);
    defer freeResult(i);
    try expectExit(i, 1);
    try expectContains(i.stdout, "status: invalid\n");
    try std.testing.expectEqualStrings("", i.stderr);
}

test "successful processing records public JSON and gzip artifacts" {
    const server = try Fixture.start(.success);
    defer stopFixture(server);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.parent_dir.realPathFileAlloc(std.testing.io, &tmp.sub_path, allocator);
    defer allocator.free(root);
    const state = try path(&.{ root, "state" });
    defer allocator.free(state);
    const base = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1", .{server.port()});
    defer allocator.free(base);
    var environment = try env(&.{ .{ "SLM_API_KEY", "secret-that-must-not-be-recorded" }, .{ "SLM_BASE_URL", base }, .{ "SLM_MODEL", "fixture-model" }, .{ "SLM_STATE_DIR", state } });
    defer environment.deinit();
    const source = "first\nsecond\x00";
    const first = try invoke(&.{ "--max-tokens=77", "summarize" }, source, &environment, .pipe);
    defer freeResult(first);
    try expectExit(first, 0);
    try std.testing.expectEqualStrings("recorded output\n", first.stdout);
    try std.testing.expectEqualStrings("", first.stderr);
    const first_metadata = try metadata(state, 1);
    defer allocator.free(first_metadata);
    const required = [_][]const u8{ "\"schema_version\":1", "\"request_format_version\":1", "\"attempt_id\":1", "\"task_instruction\":\"summarize\"", "\"model_id\":\"fixture-model\"", "\"max_tokens\":77", "\"processing_byte_limit\":16777216", "\"utf8_valid\":true", "\"kind\":\"completed\"", "\"kind\":\"content\"", "\"byte_count\":15", "\"finish_reason\":\"stop\"", "\"prompt_tokens\":9", "\"total_tokens\":12" };
    for (required) |expected| try expectContains(first_metadata, expected);
    try expectContains(first_metadata, "\"byte_count\":13");
    try expectContains(first_metadata, "\"started_at_utc\":\"");
    try expectContains(first_metadata, "\"source_ingestion\":");
    try expectContains(first_metadata, "\"model_request\":");
    try expectContains(first_metadata, "\"total\":");
    const excluded = [_][]const u8{ "secret-that-must-not-be-recorded", base, "authorization", "\"provider\"", "completion_tokens" };
    for (excluded) |secret| try expectMissing(first_metadata, secret);
    try expectMetadataInvariants(first_metadata, 1);
    const source_path = try path(&.{ state, "attempts", "1", "source-input.gz" });
    defer allocator.free(source_path);
    const output_path = try path(&.{ state, "attempts", "1", "model-output.gz" });
    defer allocator.free(output_path);
    const stored_source = try readGzip(source_path);
    defer allocator.free(stored_source);
    try std.testing.expectEqualStrings(source, stored_source);
    const stored_output = try readGzip(output_path);
    defer allocator.free(stored_output);
    try std.testing.expectEqualStrings("recorded output", stored_output);
    var opted_out_env = try env(&.{ .{ "SLM_API_KEY", "secret-that-must-not-be-recorded" }, .{ "SLM_BASE_URL", base }, .{ "SLM_MODEL", "fixture-model" }, .{ "SLM_NO_RECORD", "1" }, .{ "SLM_STATE_DIR", "relative-path-must-be-ignored" } });
    defer opted_out_env.deinit();
    const opted = try invoke(&.{ "--max-tokens=77", "summarize" }, "private", &opted_out_env, .pipe);
    defer freeResult(opted);
    try expectExit(opted, 0);
    try std.testing.expectEqualStrings("fixture refusal\n", opted.stdout);
    try std.testing.expectEqualStrings("", opted.stderr);
    const attempts_dir = try path(&.{ state, "attempts" });
    defer allocator.free(attempts_dir);
    var attempts = try std.Io.Dir.openDirAbsolute(std.testing.io, attempts_dir, .{ .iterate = true });
    defer attempts.close(std.testing.io);
    var iterator = attempts.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
    const ignored_state = try path(&.{ root, "must-not-exist" });
    defer allocator.free(ignored_state);
    var bad_env = try env(&.{ .{ "SLM_API_KEY", "secret-that-must-not-be-recorded" }, .{ "SLM_BASE_URL", base }, .{ "SLM_MODEL", "fixture-model" }, .{ "SLM_NO_RECORD", "true" }, .{ "SLM_STATE_DIR", ignored_state } });
    defer bad_env.deinit();
    const bad = try invoke(&.{ "--max-tokens=77", "summarize" }, "ignored", &bad_env, .pipe);
    defer freeResult(bad);
    try std.testing.expect(bad.term != .exited or bad.term.exited != 0);
    try std.testing.expectEqualStrings("", bad.stdout);
    try expectContains(bad.stderr, "SLM_NO_RECORD must be exactly 1");
    try expectNoPath(ignored_state);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const second = try invoke(&.{ "--max-tokens=77", "summarize" }, "again", &environment, .pipe);
    defer freeResult(second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings("fixture refusal\n", second.stdout);
    const second_metadata = try metadata(state, 2);
    defer allocator.free(second_metadata);
    try expectContains(second_metadata, "\"attempt_id\":2");
    try expectContains(second_metadata, "\"kind\":\"refusal\"");
    try expectMissing(second_metadata, "finish_reason");
    try expectMissing(second_metadata, "usage");
    const second_output_path = try recordPath(state, 2, "model-output.gz");
    defer allocator.free(second_output_path);
    const second_output = try readGzip(second_output_path);
    defer allocator.free(second_output);
    try std.testing.expectEqualStrings("fixture refusal", second_output);
    try expectMetadataInvariants(second_metadata, 2);
}

test "invalid provider responses are recorded without provider bodies" {
    const server = try Fixture.start(.failures);
    defer stopFixture(server);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.parent_dir.realPathFileAlloc(std.testing.io, &tmp.sub_path, allocator);
    defer allocator.free(root);
    const state = try path(&.{ root, "state" });
    defer allocator.free(state);
    const base = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1", .{server.port()});
    defer allocator.free(base);
    var environment = try env(&.{ .{ "SLM_API_KEY", "secret-api-key" }, .{ "SLM_BASE_URL", base }, .{ "SLM_MODEL", "fixture-model" }, .{ "SLM_STATE_DIR", state } });
    defer environment.deinit();
    const reasons = [_][]const u8{ "malformed_json", "empty_choices", "missing_output", "ambiguous_output", "response_too_large" };
    for (reasons, 1..) |reason, id| {
        const source = try std.fmt.allocPrint(allocator, "source-{s}\x00", .{reason});
        defer allocator.free(source);
        const result = try invoke(&.{ "--max-tokens=77", "summarize" }, source, &environment, .pipe);
        defer freeResult(result);
        try std.testing.expect(result.term != .exited or result.term.exited != 0);
        const expected = try std.fmt.allocPrint(allocator, "slm: invalid model response (attempt {d})\n", .{id});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, result.stderr);
        const record = try expectFailureRecord(state, id, source);
        defer allocator.free(record);
        try expectContains(record, "\"kind\":\"model_response_invalid\"");
        try expectContains(record, reason);
    }
    const http = try invoke(&.{ "--max-tokens=77", "summarize" }, "http source", &environment, .pipe);
    defer freeResult(http);
    try expectContains(http.stderr, "model request failed (attempt 6)");
    const record = try expectFailureRecord(state, 6, "http source");
    defer allocator.free(record);
    try expectContains(record, "\"http_status\":429");
    try expectContains(record, "\"kind\":\"model_request_failed\"");
    try expectMissing(record, "secret provider body");
    try expectMissing(record, "secret-api-key");
    const stopped_port = server.port();
    try server.stop();
    const network_base = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1", .{stopped_port});
    defer allocator.free(network_base);
    var network_env = try env(&.{ .{ "SLM_API_KEY", "secret-api-key" }, .{ "SLM_BASE_URL", network_base }, .{ "SLM_MODEL", "fixture-model" }, .{ "SLM_STATE_DIR", state } });
    defer network_env.deinit();
    const network = try invoke(&.{ "--max-tokens=77", "summarize" }, "network source", &network_env, .pipe);
    defer freeResult(network);
    try std.testing.expectEqualStrings("slm: model request failed (attempt 7)\n", network.stderr);
    const network_record = try expectFailureRecord(state, 7, "network source");
    defer allocator.free(network_record);
    try expectContains(network_record, "\"kind\":\"network\"");
    try expectContains(network_record, "\"error_name\":\"");
    var parsed_network = try std.json.parseFromSlice(std.json.Value, allocator, network_record, .{});
    defer parsed_network.deinit();
    const error_name = parsed_network.value.object.get("outcome").?.object.get("failure").?.object.get("error_name").?.string;
    try std.testing.expect(error_name.len > 0 and error_name.len <= 128);
    try expectMissing(network_record, "secret-api-key");
    try expectMissing(network_record, base);
}

test "source limits and UTF-8 failures retain the exact gzip source" {
    const server = try Fixture.start(.processed);
    defer stopFixture(server);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.parent_dir.realPathFileAlloc(std.testing.io, &tmp.sub_path, allocator);
    defer allocator.free(root);
    const state = try path(&.{ root, "state" });
    defer allocator.free(state);
    const base = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1", .{server.port()});
    defer allocator.free(base);
    var environment = try env(&.{ .{ "SLM_BASE_URL", base }, .{ "SLM_MODEL", "fixture-model" }, .{ "SLM_STATE_DIR", state } });
    defer environment.deinit();
    const exact = try allocator.alloc(u8, limit);
    defer allocator.free(exact);
    @memset(exact, 'a');
    const exact_result = try invoke(&.{"process"}, exact, &environment, .pipe);
    defer freeResult(exact_result);
    try expectExit(exact_result, 0);
    try std.testing.expectEqualStrings("processed\n", exact_result.stdout);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    const oversized = try allocator.alloc(u8, limit + "complete trailing bytes".len);
    defer allocator.free(oversized);
    @memset(oversized[0..limit], 'b');
    @memcpy(oversized[limit..], "complete trailing bytes");
    const result = try invoke(&.{"process"}, oversized, &environment, .pipe);
    defer freeResult(result);
    try expectContains(result.stderr, "source input too large (attempt 2)");
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    const record = try metadata(state, 2);
    defer allocator.free(record);
    try expectContains(record, "source_input_too_large");
    const source_path = try path(&.{ state, "attempts", "2", "source-input.gz" });
    defer allocator.free(source_path);
    const stored = try readGzip(source_path);
    defer allocator.free(stored);
    try std.testing.expectEqualSlices(u8, oversized, stored);

    const invalid = [_]u8{ 'a', 0xe2, 0x28, 0xa1, 'b' };
    const invalid_result = try invoke(&.{"process"}, &invalid, &environment, .pipe);
    defer freeResult(invalid_result);
    try expectContains(invalid_result.stderr, "source input is not valid UTF-8 (attempt 3)");
    const invalid_record = try metadata(state, 3);
    defer allocator.free(invalid_record);
    try expectContains(invalid_record, "source_input_invalid");
    try expectContains(invalid_record, "\"utf8_valid\":false");
    try expectContains(invalid_record, "\"model_request\":0");
    try expectMetadataInvariants(invalid_record, 3);

    const oversized_invalid = try allocator.alloc(u8, limit + 1);
    defer allocator.free(oversized_invalid);
    @memset(oversized_invalid, 'c');
    oversized_invalid[0] = 0xff;
    const oversized_invalid_result = try invoke(&.{"process"}, oversized_invalid, &environment, .pipe);
    defer freeResult(oversized_invalid_result);
    try expectContains(oversized_invalid_result.stderr, "source input too large (attempt 4)");
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    const oversized_invalid_record = try metadata(state, 4);
    defer allocator.free(oversized_invalid_record);
    try expectContains(oversized_invalid_record, "source_input_too_large");
    try expectContains(oversized_invalid_record, "\"utf8_valid\":false");

    const no_record_state = try path(&.{ root, "no-record-oversized" });
    defer allocator.free(no_record_state);
    var no_record_env = try env(&.{ .{ "SLM_BASE_URL", base }, .{ "SLM_MODEL", "fixture-model" }, .{ "SLM_NO_RECORD", "1" }, .{ "SLM_STATE_DIR", no_record_state } });
    defer no_record_env.deinit();
    const no_record_result = try invoke(&.{"process"}, oversized_invalid, &no_record_env, .pipe);
    defer freeResult(no_record_result);
    try std.testing.expectEqualStrings("slm: source input too large\n", no_record_result.stderr);
    try expectNoPath(no_record_state);

    const invalid_task = [_]u8{0xff};
    const task_result = try invoke(&.{invalid_task[0..]}, "", &environment, .pipe);
    defer freeResult(task_result);
    try expectExit(task_result, 1);
    try std.testing.expectEqualStrings("slm: task instruction is not valid UTF-8\n", task_result.stderr);
    const invalid_task_state = try path(&.{ root, "invalid-task" });
    defer allocator.free(invalid_task_state);
    var invalid_task_env = try env(&.{.{ "SLM_STATE_DIR", invalid_task_state }});
    defer invalid_task_env.deinit();
    const separate_task_result = try invoke(&.{invalid_task[0..]}, "", &invalid_task_env, .pipe);
    defer freeResult(separate_task_result);
    try expectExit(separate_task_result, 1);
    const attempts = try path(&.{ invalid_task_state, "attempts" });
    defer allocator.free(attempts);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, attempts, .{}));
}

test "closed stdout does not prevent completed record publication" {
    const server = try Fixture.start(.echo);
    defer stopFixture(server);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.parent_dir.realPathFileAlloc(std.testing.io, &tmp.sub_path, allocator);
    defer allocator.free(root);
    const state = try path(&.{ root, "state" });
    defer allocator.free(state);
    const base = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1", .{server.port()});
    defer allocator.free(base);
    var environment = try env(&.{ .{ "SLM_BASE_URL", base }, .{ "SLM_MODEL", "fixture-model" }, .{ "SLM_STATE_DIR", state } });
    defer environment.deinit();
    const result = try invoke(&.{"process"}, "closed stdout", &environment, .close);
    defer freeResult(result);
    try std.testing.expect(result.term != .exited or result.term.exited != 0);
    const output = try echoOutput("closed stdout");
    defer allocator.free(output);
    try publicRecord(state, 1, "closed stdout", output);
}

test "store hardening preserves allocation gaps and public records" {
    const server = try Fixture.start(.echo);
    defer stopFixture(server);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.parent_dir.realPathFileAlloc(std.testing.io, &tmp.sub_path, allocator);
    defer allocator.free(root);
    const state = try path(&.{ root, "state" });
    defer allocator.free(state);
    const base = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1", .{server.port()});
    defer allocator.free(base);
    var environment = try env(&.{ .{ "SLM_BASE_URL", base }, .{ "SLM_MODEL", "fixture-model" }, .{ "SLM_STATE_DIR", state } });
    defer environment.deinit();

    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 2);
    defer argv.deinit(allocator);
    try argv.append(allocator, options.slm_path);
    try argv.append(allocator, "process");
    var active = try std.process.spawn(std.testing.io, .{
        .argv = argv.items,
        .environ_map = &environment,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    try active.stdin.?.writeStreamingAll(std.testing.io, "active");

    const active_lock = try path(&.{ state, ".staging", "1", ".lock" });
    defer allocator.free(active_lock);
    const lock_deadline = std.Io.Clock.awake.now(std.testing.io).addDuration(.fromMilliseconds(1000));
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds < lock_deadline.nanoseconds) {
        if (std.Io.Dir.cwd().access(std.testing.io, active_lock, .{})) |_| break else |err| switch (err) {
            error.FileNotFound => try std.Io.sleep(std.testing.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake),
            else => return err,
        }
    } else return error.ActiveProcessDidNotCreateStagingLock;

    var concurrent = try std.process.spawn(std.testing.io, .{
        .argv = argv.items,
        .environ_map = &environment,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    try concurrent.stdin.?.writeStreamingAll(std.testing.io, "concurrent");
    concurrent.stdin.?.close(std.testing.io);
    concurrent.stdin = null;
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try waitForExit(&concurrent, 1000));
    const concurrent_output = try echoOutput("concurrent");
    defer allocator.free(concurrent_output);
    try publicRecord(state, 2, "concurrent", concurrent_output);
    const active_attempt = try recordPath(state, 1, ".");
    defer allocator.free(active_attempt);
    try expectNoPath(active_attempt);
    try std.Io.Dir.cwd().access(std.testing.io, active_lock, .{});

    active.stdin.?.close(std.testing.io);
    active.stdin = null;
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try waitForExit(&active, 1000));
    const active_output = try echoOutput("active");
    defer allocator.free(active_output);
    try publicRecord(state, 1, "active", active_output);

    const staging = try path(&.{ state, ".staging" });
    defer allocator.free(staging);
    const stale = try path(&.{ staging, "99" });
    defer allocator.free(stale);
    try std.Io.Dir.cwd().createDir(std.testing.io, stale, std.Io.File.Permissions.fromMode(0o700));
    const stale_lock = try path(&.{ stale, ".lock" });
    defer allocator.free(stale_lock);
    const stale_lock_file = try std.Io.Dir.cwd().createFile(std.testing.io, stale_lock, .{ .exclusive = true });
    stale_lock_file.close(std.testing.io);
    const cleaned = try invoke(&.{"process"}, "cleaned", &environment, .pipe);
    defer freeResult(cleaned);
    try expectExit(cleaned, 0);
    const cleaned_output = try echoOutput("cleaned");
    defer allocator.free(cleaned_output);
    try publicRecord(state, 3, "cleaned", cleaned_output);
    try expectNoPath(stale);
    const stale_allocation = try path(&.{ state, ".allocated", "99" });
    defer allocator.free(stale_allocation);
    try expectNoPath(stale_allocation);

    const stages = [_][]const u8{ "capture_sync", "final_sync", "publication_sync" };
    for (stages, 4..) |failure_point, id| {
        var broken = try env(&.{ .{ "SLM_BASE_URL", base }, .{ "SLM_MODEL", "fixture-model" }, .{ "SLM_STATE_DIR", state }, .{ "SLM_TEST_STORAGE_FAILURE", failure_point } });
        defer broken.deinit();
        const result = try invoke(&.{"process"}, "failure", &broken, .pipe);
        defer freeResult(result);
        try std.testing.expect(result.term != .exited or result.term.exited != 0);
        try expectContains(result.stderr, "InjectedStorageFailure");
        const attempt = try recordPath(state, id, ".");
        defer allocator.free(attempt);
        try expectNoPath(attempt);
    }
    var published = try env(&.{ .{ "SLM_BASE_URL", base }, .{ "SLM_MODEL", "fixture-model" }, .{ "SLM_STATE_DIR", state }, .{ "SLM_TEST_STORAGE_FAILURE", "published_sync" } });
    defer published.deinit();
    const published_result = try invoke(&.{"process"}, "published", &published, .pipe);
    defer freeResult(published_result);
    try std.testing.expect(published_result.term != .exited or published_result.term.exited != 0);
    try expectContains(published_result.stderr, "InjectedStorageFailure");
    const published_output = try echoOutput("published");
    defer allocator.free(published_output);
    try publicRecord(state, 7, "published", published_output);

    const after = try invoke(&.{"process"}, "after", &environment, .pipe);
    defer freeResult(after);
    try expectExit(after, 0);
    const after_output = try echoOutput("after");
    defer allocator.free(after_output);
    try publicRecord(state, 8, "after", after_output);

    const next_id = try path(&.{ state, ".next-id" });
    defer allocator.free(next_id);
    const closed = try invoke(&.{"process"}, "closed", &environment, .close);
    defer freeResult(closed);
    try std.testing.expect(closed.term != .exited or closed.term.exited != 0);
    const closed_output = try echoOutput("closed");
    defer allocator.free(closed_output);
    try publicRecord(state, 9, "closed", closed_output);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, next_id);
    const recovered_again = try invoke(&.{"process"}, "recovered again", &environment, .pipe);
    defer freeResult(recovered_again);
    try expectExit(recovered_again, 0);
    const recovered_again_output = try echoOutput("recovered again");
    defer allocator.free(recovered_again_output);
    try publicRecord(state, 10, "recovered again", recovered_again_output);
    try std.testing.expectEqual(@as(usize, 9), server.requestCount());
}

test "unsafe state directory is rejected before stdin EOF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.parent_dir.realPathFileAlloc(std.testing.io, &tmp.sub_path, allocator);
    defer allocator.free(root);
    const state = try path(&.{ root, "unsafe" });
    defer allocator.free(state);
    try std.Io.Dir.cwd().createDir(std.testing.io, state, std.Io.File.Permissions.fromMode(0o755));
    const state_dir = try std.Io.Dir.openFileAbsolute(std.testing.io, state, .{ .allow_directory = true });
    defer state_dir.close(std.testing.io);
    try state_dir.setPermissions(std.testing.io, std.Io.File.Permissions.fromMode(0o755));

    var environment = try env(&.{ .{ "SLM_BASE_URL", "http://127.0.0.1:1/v1" }, .{ "SLM_MODEL", "fixture-model" }, .{ "SLM_STATE_DIR", state } });
    defer environment.deinit();
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 2);
    defer argv.deinit(allocator);
    try argv.append(allocator, options.slm_path);
    try argv.append(allocator, "process");
    var child = try std.process.spawn(std.testing.io, .{
        .argv = argv.items,
        .environ_map = &environment,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer if (child.stdin) |stdin| stdin.close(std.testing.io);
    var waiter: Waiter = .{ .child = &child };
    const waiter_thread = try std.Thread.spawn(.{}, Waiter.wait, .{&waiter});
    defer waiter_thread.join();
    const deadline = std.Io.Clock.awake.now(std.testing.io).addDuration(.fromMilliseconds(1000));
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline.nanoseconds) {
        if (waiter.done.load(.acquire)) break;
        try std.Io.sleep(std.testing.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake);
    }
    if (!waiter.done.load(.acquire)) {
        child.kill(std.testing.io);
        return error.ProcessDidNotRejectUnsafeStateDirectory;
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, waiter.result.?);
}
