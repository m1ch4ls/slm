# slm

A small Zig CLI for piping text through an OpenAI-compatible Chat Completions API.

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

Use explicit configuration for a local or other OpenAI-compatible endpoint:

```sh
export SLM_BASE_URL=http://localhost:11434/v1
export SLM_MODEL=qwen2.5:1.5b
# Optional bearer token:
export SLM_API_KEY=...
```

`SLM_BASE_URL` and `SLM_MODEL` must be set together. A complete `--base-url` and
`--model` pair overrides them. Plain HTTP is supported, but transmits the source
input and `SLM_API_KEY` without transport security.

Without explicit configuration, `slm` selects the cheapest model among providers
with a configured credential:

```sh
export OPENAI_API_KEY=...
export GEMINI_API_KEY=...
export ANTHROPIC_API_KEY=...
```

Provider credentials are used only for automatic selection. `OPENAI_API_KEY`
always means OpenAI direct; use `SLM_*` for third-party gateways. Empty credential
variables are invalid configuration. Selection is local and does not test model
access, account status, or regional availability. A failed request is never retried
through another provider.

### Automatic Model Pricing

The cheapest model minimizes estimated token cost for a workload composed of 90%
uncached input tokens and 10% output tokens. Standard synchronous paid-tier prices
are compared; free tiers, caching, batch discounts, promotions, and negotiated
prices are ignored. Exact ties prefer Google Gemini, then OpenAI, then Anthropic.
Different provider tokenizers mean the result is an estimate, not an equal-request
billing prediction.

<!-- BEGIN GENERATED MODEL TABLE -->
| Provider | Model | Input / 1M tokens | Output / 1M tokens | Estimated weighted cost |
| --- | --- | ---: | ---: | ---: |
| OpenAI | `gpt-5-nano` | $0.05 | $0.40 | $0.085 |
| Google Gemini | `gemini-2.5-flash-lite` | $0.10 | $0.40 | $0.13 |
| Anthropic | `claude-haiku-4-5` | $1.00 | $5.00 | $1.40 |
<!-- END GENERATED MODEL TABLE -->

The committed model manifest is generated from the MIT-licensed
[models.dev catalog](https://models.dev). Eligible models must be generally
available text models with positive standard prices, no conditional pricing, and
enough context and output capacity for `slm` defaults. Anthropic's OpenAI
compatibility layer is intended primarily for model evaluation, but supports the
basic non-streaming text requests used here.

## Usage

```sh
git diff | zig-out/bin/slm "summarize in 3 bullets"
ps aux | zig-out/bin/slm --model qwen2.5:1.5b --base-url http://localhost:11434/v1 "list only node processes"
zig-out/bin/slm --debug-config
zig-out/bin/slm --help
```

The CLI accepts `--base-url`, `--model`, and `--max-tokens`. `--base-url` and
`--model` must be passed together. Requests are sent to
`<base-url>/chat/completions`; pass an API root, not the full endpoint. Model
requests do not follow redirects. Task instructions must be valid UTF-8 and no
larger than 16 KiB.

`--debug-config` resolves environment configuration without consuming stdin,
recording an attempt, or contacting a provider. It prints only the effective
configuration and credential variable name, never credential values.

Processing attempts are recorded by default in the per-user state directory. Set an
absolute `SLM_STATE_DIR` to relocate the store or `SLM_NO_RECORD=1` to disable all
recording. The finalized JSON/gzip interchange contract is documented in
[`docs/processing-attempt-store.md`](docs/processing-attempt-store.md).

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

Refresh the model manifest and generated pricing table from models.dev with:

```sh
mise exec -- zig build update-models
mise exec -- zig build update-models -Daccept-model-update=true
```

The first command prints changes and exits non-zero. The second accepts validated
changes. Normal builds are offline and consume the reviewed committed manifest.

The project intentionally uses only Zig's standard library: manual argument parsing,
`std.http.Client`, and typed `std.json` decoding. This keeps the binary dependency-free
and avoids coupling a tiny command surface to a third-party CLI package.
