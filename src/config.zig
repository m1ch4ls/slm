const std = @import("std");
const cli = @import("cli.zig");
const manifest = @import("model_manifest.zig");

pub const Environment = struct {
    slm_base_url: ?[]const u8 = null,
    slm_model: ?[]const u8 = null,
    slm_api_key: ?[]const u8 = null,
    openai_api_key: ?[]const u8 = null,
    gemini_api_key: ?[]const u8 = null,
    anthropic_api_key: ?[]const u8 = null,
};

pub const Explicit = struct { base_url: []const u8, model: []const u8, api_key: ?[]const u8 };
pub const Automatic = struct { provider: manifest.Provider, entry: manifest.Entry, api_key: []const u8 };
pub const Resolved = union(enum) { explicit: Explicit, automatic: Automatic };

pub const ResolveError = error{
    IncompleteCliConfiguration,
    IncompleteEnvironmentConfiguration,
    EmptyApiKey,
    EmptyProviderCredential,
    NoProviderCredentials,
    InvalidBaseUrl,
    InvalidModel,
};

pub fn resolve(parsed: cli.Config, env: Environment) ResolveError!Resolved {
    if (parsed.model != null or parsed.base_url != null) {
        if (parsed.model == null or parsed.base_url == null) return error.IncompleteCliConfiguration;
        return .{ .explicit = try explicit(parsed.base_url.?, parsed.model.?, env.slm_api_key) };
    }
    if (env.slm_base_url != null or env.slm_model != null or env.slm_api_key != null) {
        if (env.slm_base_url == null or env.slm_model == null) return error.IncompleteEnvironmentConfiguration;
        return .{ .explicit = try explicit(env.slm_base_url.?, env.slm_model.?, env.slm_api_key) };
    }

    const credentials = [_]?[]const u8{ env.gemini_api_key, env.openai_api_key, env.anthropic_api_key };
    inline for (credentials) |credential| if (credential) |value| if (value.len == 0) return error.EmptyProviderCredential;

    var selected: ?Automatic = null;
    inline for (std.meta.tags(manifest.Provider), credentials) |provider, credential| {
        if (credential) |api_key| {
            const candidate = manifest.entry(provider);
            if (selected == null or candidate.score() < selected.?.entry.score())
                selected = .{ .provider = provider, .entry = candidate, .api_key = api_key };
        }
    }
    return .{ .automatic = selected orelse return error.NoProviderCredentials };
}

fn explicit(base_url: []const u8, model: []const u8, api_key: ?[]const u8) ResolveError!Explicit {
    if (api_key) |value| if (value.len == 0) return error.EmptyApiKey;
    if (!validModel(model)) return error.InvalidModel;
    if (!validBaseUrl(base_url)) return error.InvalidBaseUrl;
    return .{ .base_url = base_url, .model = model, .api_key = api_key };
}

fn validModel(value: []const u8) bool {
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn validBaseUrl(value: []const u8) bool {
    const uri = std.Uri.parse(value) catch return false;
    if (uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return false;
    const scheme = uri.scheme;
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) return false;
    return !std.mem.endsWith(u8, std.mem.trimEnd(u8, value, "/"), "/chat/completions");
}

test "automatic selection chooses cheapest configured provider" {
    const resolved = try resolve(.{}, .{ .openai_api_key = "openai", .gemini_api_key = "gemini" });
    try std.testing.expectEqual(manifest.Provider.openai, resolved.automatic.provider);
}

test "complete CLI configuration ignores incomplete environment pair" {
    const resolved = try resolve(.{ .model = "m", .base_url = "http://localhost/v1" }, .{ .slm_model = "ignored" });
    try std.testing.expectEqualStrings("m", resolved.explicit.model);
}
