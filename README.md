# slm

A small Zig CLI for piping text through an OpenAI-compatible Chat Completions API.
It keeps the useful command contract from `token-saver` without its local model daemon.

## Requirements

- Zig 0.16.0
- An OpenAI-compatible `/v1/chat/completions` endpoint

The Zig version is pinned in `mise.toml`.

## Build

```sh
mise install
mise exec -- zig build
```

The binary is written to `zig-out/bin/slm`.

## Configuration

```sh
export OPENAI_BASE_URL=http://localhost:11434/v1
export OPENAI_MODEL=qwen2.5:1.5b
# Optional for local endpoints:
export OPENAI_API_KEY=...
```

`OPENAI_BASE_URL` defaults to `https://api.openai.com/v1`. `OPENAI_MODEL` is
required unless `--model` is provided. `OPENAI_API_KEY` is optional because many
local compatible servers do not require authentication.

## Usage

```sh
git diff | zig-out/bin/slm "summarize in 3 bullets"
ps aux | zig-out/bin/slm --model qwen2.5:1.5b "list only node processes"
zig-out/bin/slm --help
```

The CLI accepts `--base-url`, `--model`, and `--max-tokens`. Requests are sent to
`<base-url>/chat/completions`; pass a base URL ending in `/v1`, not the full endpoint.

## Agent Skill

Print the canonical agent instructions:

```sh
slm skill
```

Register them with an agent by redirecting the output to that agent's skill location:

```sh
slm skill > /path/to/agent/skills/slm/SKILL.md
```

## Development

```sh
mise exec -- zig fmt build.zig src
mise exec -- zig build test
```

The project intentionally uses only Zig's standard library: manual argument parsing,
`std.http.Client`, and typed `std.json` decoding. This keeps the binary dependency-free
and avoids coupling a tiny command surface to a third-party CLI package.
