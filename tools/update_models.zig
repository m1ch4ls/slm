const std = @import("std");

const providers = [_][]const u8{ "openai", "google", "anthropic" };
const excluded = [_][]const u8{ "preview", "experimental", "alpha", "beta", "deprecated", "embedding", "realtime", "audio", "image", "transcribe", "tts", "moderation" };

const Candidate = struct {
    provider: []const u8,
    model: []const u8,
    input_price: u64,
    output_price: u64,
    context_limit: u64,
    output_limit: u64,

    fn score(self: Candidate) u64 {
        return 9 * self.input_price + self.output_price;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const accept = args.len == 2 and std.mem.eql(u8, args[1], "--accept");
    if (args.len > 2 or (args.len == 2 and !accept)) return error.InvalidArguments;

    const body = try fetch(allocator, init.io);
    defer allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .parse_numbers = false });
    defer parsed.deinit();

    var selected: [providers.len]Candidate = undefined;
    for (providers, 0..) |provider, index| selected[index] = try selectProvider(parsed.value, provider);

    const timestamp = try formatUtcNow(allocator, init.io);
    defer allocator.free(timestamp);
    const manifest = try renderManifest(allocator, timestamp, selected);
    defer allocator.free(manifest);

    const cwd = std.Io.Dir.cwd();
    const old_manifest = try cwd.readFileAlloc(init.io, "src/models.tsv", allocator, .limited(1024 * 1024));
    defer allocator.free(old_manifest);
    const manifest_changed = !sameRows(old_manifest, manifest);

    const readme = try cwd.readFileAlloc(init.io, "README.md", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(readme);
    const updated_readme = try renderReadme(allocator, readme, selected);
    defer allocator.free(updated_readme);
    const readme_changed = !std.mem.eql(u8, readme, updated_readme);

    if (!manifest_changed and !readme_changed) return;
    try report(init.io, selected, manifest_changed, readme_changed);
    if (!accept) return error.ModelUpdateRequiresAcceptance;

    if (readme_changed) try cwd.writeFile(init.io, .{ .sub_path = "README.md.tmp", .data = updated_readme });
    if (manifest_changed) try cwd.writeFile(init.io, .{ .sub_path = "src/models.tsv.tmp", .data = manifest });
    if (readme_changed) try cwd.rename("README.md.tmp", cwd, "README.md", init.io);
    if (manifest_changed) try cwd.rename("src/models.tsv.tmp", cwd, "src/models.tsv", init.io);
}

fn fetch(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse("https://models.dev/api.json"), .{
        .redirect_behavior = .init(5),
        .headers = .{ .accept_encoding = .{ .override = "gzip" } },
    });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status.class() != .success) return error.CatalogRequestFailed;
    var read_buffer: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    return response.readerDecompressing(&read_buffer, &decompress, &decompress_buffer)
        .allocRemaining(allocator, .limited(64 * 1024 * 1024));
}

fn selectProvider(root: std.json.Value, provider_id: []const u8) !Candidate {
    const provider = objectGet(root, provider_id) orelse return error.MissingProvider;
    const models = objectGet(provider, "models") orelse return error.InvalidCatalog;
    var best: ?Candidate = null;
    var iterator = models.object.iterator();
    while (iterator.next()) |item| {
        const candidate = parseCandidate(provider_id, item.key_ptr.*, item.value_ptr.*) catch continue;
        if (best == null or candidate.score() < best.?.score() or
            (candidate.score() == best.?.score() and std.mem.order(u8, candidate.model, best.?.model) == .lt)) best = candidate;
    }
    return best orelse error.NoEligibleModel;
}

fn parseCandidate(provider: []const u8, id: []const u8, value: std.json.Value) !Candidate {
    if (value != .object) return error.InvalidCatalog;
    if (objectGet(value, "status") != null or objectGet(value, "experimental") != null) return error.Ineligible;
    const name = stringValue(objectGet(value, "name") orelse return error.Ineligible) orelse return error.Ineligible;
    for (excluded) |term| {
        if (containsIgnoreCase(id, term) or containsIgnoreCase(name, term)) return error.Ineligible;
    }
    const modalities = objectGet(value, "modalities") orelse return error.Ineligible;
    if (!arrayContainsString(objectGet(modalities, "input") orelse return error.Ineligible, "text") or
        !arrayContainsString(objectGet(modalities, "output") orelse return error.Ineligible, "text")) return error.Ineligible;

    const cost = objectGet(value, "cost") orelse return error.Ineligible;
    if (cost != .object) return error.Ineligible;
    var cost_iterator = cost.object.iterator();
    while (cost_iterator.next()) |item| {
        const key = item.key_ptr.*;
        if (!std.mem.eql(u8, key, "input") and !std.mem.eql(u8, key, "output") and
            !std.mem.eql(u8, key, "cache_read") and !std.mem.eql(u8, key, "cache_write")) return error.Ineligible;
    }
    const input_price = try price(objectGet(cost, "input") orelse return error.Ineligible);
    const output_price = try price(objectGet(cost, "output") orelse return error.Ineligible);
    if (input_price == 0 or output_price == 0) return error.Ineligible;

    const limit = objectGet(value, "limit") orelse return error.Ineligible;
    const context_limit = try integer(objectGet(limit, "context") orelse return error.Ineligible);
    const output_limit = try integer(objectGet(limit, "output") orelse return error.Ineligible);
    if (output_limit < 16_384 or context_limit < 16 * 1024 + 16_384) return error.Ineligible;
    return .{ .provider = provider, .model = id, .input_price = input_price, .output_price = output_price, .context_limit = context_limit, .output_limit = output_limit };
}

fn objectGet(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn stringValue(value: std.json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

fn arrayContainsString(value: std.json.Value, expected: []const u8) bool {
    if (value != .array) return false;
    for (value.array.items) |item| if (item == .string and std.mem.eql(u8, item.string, expected)) return true;
    return false;
}

fn integer(value: std.json.Value) !u64 {
    const text = if (value == .number_string) value.number_string else return error.InvalidNumber;
    if (std.mem.indexOfAny(u8, text, ".eE") != null) return error.InvalidNumber;
    return std.fmt.parseInt(u64, text, 10);
}

fn price(value: std.json.Value) !u64 {
    const text = if (value == .number_string) value.number_string else return error.InvalidNumber;
    if (std.mem.indexOfAny(u8, text, "eE") != null) return error.InvalidNumber;
    const dot = std.mem.indexOfScalar(u8, text, '.');
    const whole = try std.fmt.parseInt(u64, if (dot) |index| text[0..index] else text, 10);
    const fraction = if (dot) |index| text[index + 1 ..] else "";
    if (fraction.len > 6) return error.InvalidNumber;
    var result = try std.math.mul(u64, whole, 1_000_000);
    if (fraction.len > 0) {
        var scale: u64 = 1_000_000;
        for (fraction) |digit| {
            if (!std.ascii.isDigit(digit)) return error.InvalidNumber;
            scale /= 10;
            result = try std.math.add(u64, result, (digit - '0') * scale);
        }
    }
    return result;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn renderManifest(allocator: std.mem.Allocator, timestamp: []const u8, selected: [3]Candidate) ![]u8 {
    return std.fmt.allocPrint(allocator, "# source=https://models.dev/api.json\n# updated_at={s}\nprovider\tmodel\tinput_micro_usd_per_mtok\toutput_micro_usd_per_mtok\tcontext_limit\toutput_limit\n" ++
        "{s}\t{s}\t{d}\t{d}\t{d}\t{d}\n{s}\t{s}\t{d}\t{d}\t{d}\t{d}\n{s}\t{s}\t{d}\t{d}\t{d}\t{d}\n", .{ timestamp, selected[0].provider, selected[0].model, selected[0].input_price, selected[0].output_price, selected[0].context_limit, selected[0].output_limit, selected[1].provider, selected[1].model, selected[1].input_price, selected[1].output_price, selected[1].context_limit, selected[1].output_limit, selected[2].provider, selected[2].model, selected[2].input_price, selected[2].output_price, selected[2].context_limit, selected[2].output_limit });
}

fn sameRows(old: []const u8, new: []const u8) bool {
    const old_rows = std.mem.indexOf(u8, old, "provider\t") orelse return false;
    const new_rows = std.mem.indexOf(u8, new, "provider\t") orelse return false;
    return std.mem.eql(u8, old[old_rows..], new[new_rows..]);
}

fn renderReadme(allocator: std.mem.Allocator, readme: []const u8, selected: [3]Candidate) ![]u8 {
    const begin = "<!-- BEGIN GENERATED MODEL TABLE -->";
    const end = "<!-- END GENERATED MODEL TABLE -->";
    const start = std.mem.indexOf(u8, readme, begin) orelse return error.ReadmeMarkersMissing;
    const finish_start = std.mem.indexOfPos(u8, readme, start, end) orelse return error.ReadmeMarkersMissing;
    const finish = finish_start + end.len;
    const table = try std.fmt.allocPrint(allocator, "{s}\n| Provider | Model | Input / 1M tokens | Output / 1M tokens | Estimated weighted cost |\n| --- | --- | ---: | ---: | ---: |\n" ++
        "| OpenAI | `{s}` | ${d}.{d:0>6} | ${d}.{d:0>6} | ${d}.{d:0>6} |\n" ++
        "| Google Gemini | `{s}` | ${d}.{d:0>6} | ${d}.{d:0>6} | ${d}.{d:0>6} |\n" ++
        "| Anthropic | `{s}` | ${d}.{d:0>6} | ${d}.{d:0>6} | ${d}.{d:0>6} |\n{s}", .{ begin, selected[0].model, selected[0].input_price / 1_000_000, selected[0].input_price % 1_000_000, selected[0].output_price / 1_000_000, selected[0].output_price % 1_000_000, selected[0].score() / 10 / 1_000_000, selected[0].score() / 10 % 1_000_000, selected[1].model, selected[1].input_price / 1_000_000, selected[1].input_price % 1_000_000, selected[1].output_price / 1_000_000, selected[1].output_price % 1_000_000, selected[1].score() / 10 / 1_000_000, selected[1].score() / 10 % 1_000_000, selected[2].model, selected[2].input_price / 1_000_000, selected[2].input_price % 1_000_000, selected[2].output_price / 1_000_000, selected[2].output_price % 1_000_000, selected[2].score() / 10 / 1_000_000, selected[2].score() / 10 % 1_000_000, end });
    defer allocator.free(table);
    return std.mem.concat(allocator, u8, &.{ readme[0..start], table, readme[finish..] });
}

fn report(io: std.Io, selected: [3]Candidate, manifest_changed: bool, readme_changed: bool) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print("model update: manifest={s}, readme={s}\n", .{ if (manifest_changed) "changed" else "unchanged", if (readme_changed) "changed" else "unchanged" });
    for (selected) |candidate| try writer.interface.print("  {s}: {s} ({d})\n", .{ candidate.provider, candidate.model, candidate.score() });
    try writer.interface.flush();
}

fn formatUtcNow(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const now = std.Io.Clock.real.now(io);
    const seconds: u64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
}
