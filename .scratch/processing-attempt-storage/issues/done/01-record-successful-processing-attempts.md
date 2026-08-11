# Record successful Processing attempts

Status: done
Execution: AFK

## What to build

Record the complete successful Processing attempt path in the local per-user store. A valid invocation should resolve secure storage, capture byte-exact Source input, call the Delegated language model, capture structured Model output, publish a versioned immutable record, and preserve the existing stdout contract. Recording is enabled by default and `SLM_NO_RECORD=1` bypasses the store completely.

The completed record must contain the agreed semantic request context and evaluation metadata without endpoint, credential, transport, or ambient process data. Content and refusal are distinct Model output kinds; finish reason and usage counts are optional provider facts.

## Acceptance criteria

- [x] A successful invocation with recording enabled creates one finalized `completed` record containing the Task instruction, full Runtime system prompt, effective model ID, `max_tokens`, request-format/schema versions, configured processing limit, byte counts, UTF-8 fact, UTC start time, split durations, and structured Model output metadata.
- [x] Decompressing the stored Source input and Model output reproduces the exact stdin bytes and pre-newline delegated text respectively; both payloads use gzip level 1.
- [x] Content and refusal are represented as distinct output kinds, with optional finish reason and optional prompt/completion/total usage counts preserving absence rather than converting it to zero.
- [x] Successful stdout remains exactly the current Model output plus existing newline normalization, successful stderr remains empty, and no attempt ID is emitted.
- [x] `SLM_NO_RECORD=1` performs no store access or side effect, while any other present value is rejected before stdin is consumed.
- [x] Help, Agent skill output, invalid arguments, missing required configuration, and other invocations that never become Processing attempts create no record.
- [x] Storage resolves from an absolute `SLM_STATE_DIR`, then XDG state, then the home state fallback; relative overrides and unusable state configuration fail before stdin consumption.
- [x] Newly created storage is owner-only, existing group/world-accessible store paths are rejected rather than modified, and no automatic pruning is introduced.
- [x] Attempt IDs are short monotonically increasing local decimal integers; allocation state and unfinished writes are not part of the finalized public record.
- [x] Persisted data excludes base URLs, API credentials, authorization headers, raw API exchanges, response bodies, stdout/stderr, argv, current directory, host/user identity, and unrelated environment values.
- [x] Focused store, completion, and process-level tests verify behavior through finalized records, decompressed payloads, metadata semantics, process streams, and exit status rather than private helpers or incidental JSON ordering.

## Blocked by

None - can start immediately
