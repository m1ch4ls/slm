const std = @import("std");
const limits = @import("limits.zig");

pub const Provider = enum {
    google,
    openai,
    anthropic,

    pub fn id(self: Provider) []const u8 {
        return @tagName(self);
    }

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .google => "Google Gemini",
            .openai => "OpenAI",
            .anthropic => "Anthropic",
        };
    }

    pub fn baseUrl(self: Provider) []const u8 {
        return switch (self) {
            .google => "https://generativelanguage.googleapis.com/v1beta/openai",
            .openai => "https://api.openai.com/v1",
            .anthropic => "https://api.anthropic.com/v1",
        };
    }

    pub fn credentialVariable(self: Provider) []const u8 {
        return switch (self) {
            .google => "GEMINI_API_KEY",
            .openai => "OPENAI_API_KEY",
            .anthropic => "ANTHROPIC_API_KEY",
        };
    }
};

pub const Entry = struct {
    provider: Provider,
    model: []const u8,
    input_price: u64,
    output_price: u64,
    context_limit: u64,
    output_limit: u64,

    pub fn score(self: Entry) u64 {
        return 9 * self.input_price + self.output_price;
    }
};

pub const updated_at = metadataValue(@embedFile("models.tsv"), "# updated_at=");
pub const entries = parse(@embedFile("models.tsv"));

pub fn entry(provider: Provider) Entry {
    for (entries) |value| if (value.provider == provider) return value;
    unreachable;
}

fn metadataValue(comptime source: []const u8, comptime prefix: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    }
    @compileError("model manifest is missing metadata");
}

fn parse(comptime source: []const u8) [3]Entry {
    @setEvalBranchQuota(10_000);
    var result: [3]Entry = undefined;
    var count: usize = 0;
    var saw_header = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (!saw_header) {
            if (!std.mem.eql(u8, line, "provider\tmodel\tinput_micro_usd_per_mtok\toutput_micro_usd_per_mtok\tcontext_limit\toutput_limit"))
                @compileError("invalid model manifest header");
            saw_header = true;
            continue;
        }
        if (count == result.len) @compileError("model manifest must contain exactly three rows");
        var fields = std.mem.splitScalar(u8, line, '\t');
        const provider_text = fields.next() orelse @compileError("invalid model manifest row");
        const model = fields.next() orelse @compileError("invalid model manifest row");
        const input_price = parseInt(fields.next() orelse @compileError("invalid model manifest row"));
        const output_price = parseInt(fields.next() orelse @compileError("invalid model manifest row"));
        const context_limit = parseInt(fields.next() orelse @compileError("invalid model manifest row"));
        const output_limit = parseInt(fields.next() orelse @compileError("invalid model manifest row"));
        if (fields.next() != null) @compileError("invalid model manifest row");
        const provider: Provider = if (std.mem.eql(u8, provider_text, "google"))
            .google
        else if (std.mem.eql(u8, provider_text, "openai"))
            .openai
        else if (std.mem.eql(u8, provider_text, "anthropic"))
            .anthropic
        else
            @compileError("unknown manifest provider");
        if (model.len == 0 or input_price == 0 or output_price == 0) @compileError("invalid model manifest values");
        if (output_limit < limits.default_max_tokens) @compileError("manifest model output limit is too small");
        result[count] = .{ .provider = provider, .model = model, .input_price = input_price, .output_price = output_price, .context_limit = context_limit, .output_limit = output_limit };
        count += 1;
    }
    if (!saw_header or count != result.len) @compileError("model manifest must contain exactly three rows");
    inline for (std.meta.tags(Provider)) |provider| {
        var found = false;
        for (result) |value| found = found or value.provider == provider;
        if (!found) @compileError("model manifest is missing a provider");
    }
    return result;
}

fn parseInt(comptime value: []const u8) u64 {
    return std.fmt.parseInt(u64, value, 10) catch @compileError("invalid manifest integer");
}

test "provider tie order is declaration order" {
    try std.testing.expectEqual(Provider.google, std.meta.tags(Provider)[0]);
}
