const std = @import("std");
const protocol = @import("protocol.zig");

const log = std.log.scoped(.slm);

const DaemonClient = struct {
    socket_path: []const u8,
    socket: ?std.posix.fd_t,

    pub fn init(allocator: std.mem.Allocator) !DaemonClient {
        const uid = std.os.linux.getuid();
        const socket_path = try std.fmt.allocPrint(allocator, "/run/user/{d}/slm/daemon.sock", .{uid});

        return DaemonClient{
            .socket_path = socket_path,
            .socket = null,
        };
    }

    pub fn deinit(self: *DaemonClient, allocator: std.mem.Allocator) void {
        if (self.socket) |sock| {
            std.posix.close(sock);
        }
        allocator.free(self.socket_path);
    }

    pub fn connect(self: *DaemonClient) !void {
        const socket_path_z = try std.heap.page_allocator.dupeZ(u8, self.socket_path);
        defer std.heap.page_allocator.free(socket_path_z);

        var addr: std.posix.sockaddr.un = std.mem.zeroes(std.posix.sockaddr.un);
        addr.family = std.posix.AF.UNIX;
        const max_path = @min(self.socket_path.len, addr.path.len - 1);
        @memcpy(addr.path[0..max_path], self.socket_path[0..max_path]);
        addr.path[max_path] = 0;

        var retries: usize = 0;
        const max_retries: usize = 10;

        while (retries < max_retries) : (retries += 1) {
            const sock = std.posix.socket(
                std.posix.AF.UNIX,
                std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
                0,
            ) catch |err| {
                log.err("Failed to create socket: {}", .{err});
                return err;
            };

            const addr_ptr: *const std.posix.sockaddr = @ptrCast(&addr);
            std.posix.connect(sock, addr_ptr, @sizeOf(std.posix.sockaddr.un)) catch |err| {
                std.posix.close(sock);

                if (err == error.ConnectionRefused or err == error.FileNotFound) {
                    log.info("Daemon not running, starting... (attempt {d}/{d})", .{ retries + 1, max_retries });
                    try self.spawnDaemon();
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                    continue;
                }
                log.err("Failed to connect to daemon: {}", .{err});
                return err;
            };

            self.socket = sock;
            return;
        }

        return error.DaemonFailedToStart;
    }

    fn spawnDaemon(self: *DaemonClient) !void {
        _ = self;
        const self_exe = try std.fs.selfExePathAlloc(std.heap.page_allocator);
        defer std.heap.page_allocator.free(self_exe);

        const daemon_path = blk: {
            const dir = std.fs.path.dirname(self_exe) orelse "/usr/bin";
            break :blk try std.fs.path.join(std.heap.page_allocator, &.{ dir, "slm-daemon" });
        };
        defer std.heap.page_allocator.free(daemon_path);

        var child = std.process.Child.init(&[_][]const u8{daemon_path}, std.heap.page_allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
    }

    pub fn sendRequest(self: *DaemonClient, request: protocol.Request) !void {
        const socket = self.socket orelse return error.NotConnected;
        const file = std.fs.File{ .handle = socket };

        try protocol.writeRequest(file, request);
    }

    pub fn readResponse(self: *DaemonClient, allocator: std.mem.Allocator) !void {
        const socket = self.socket orelse return error.NotConnected;
        const file = std.fs.File{ .handle = socket };

        const stdout = std.fs.File.stdout();

        while (true) {
            const token = (try protocol.readToken(file, allocator)) orelse break;
            defer allocator.free(token);

            try stdout.writeAll(token);
        }
        try stdout.writeAll("\n");
    }
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        log.err("Usage: slm <prompt>", .{});
        log.err("       echo 'text' | slm 'extract emails'", .{});
        return error.MissingPrompt;
    }
    const user_prompt = args[1];

    const stdin_content = try readStdin(allocator);
    defer allocator.free(stdin_content);

    var client = try DaemonClient.init(allocator);
    defer client.deinit(allocator);

    try client.connect();

    const request = protocol.Request{
        .prompt = user_prompt,
        .stdin = stdin_content,
        .max_tokens = 10240,
    };

    try client.sendRequest(request);
    try client.readResponse(allocator);
}

fn readStdin(allocator: std.mem.Allocator) ![]const u8 {
    const stdin = std.fs.File.stdin();

    var content = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer content.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stdin.read(&buf) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;
        try content.appendSlice(allocator, buf[0..n]);
    }

    return content.toOwnedSlice(allocator);
}
