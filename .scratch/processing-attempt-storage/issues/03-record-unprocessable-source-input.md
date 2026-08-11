# Record unprocessable Source input

Status: ready-for-agent
Execution: AFK

## What to build

Capture stdin as a stream so Source input that cannot be delegated is still recorded completely and classified deterministically. Recording mode must tee bytes into compressed storage while retaining at most the 16 MiB processable prefix in memory. Oversized streams continue through EOF and finalize `source_input_too_large`; within-limit invalid UTF-8 finalizes `source_input_invalid`. Neither outcome calls the Delegated language model.

## Acceptance criteria

- [ ] Empty, within-limit, exact-limit, and one-byte-over-limit stdin are classified correctly while byte counts and UTF-8 validity are collected across arbitrary reader chunk boundaries.
- [ ] Once recording-mode Source input exceeds 16 MiB, `slm` continues reading through EOF, stores every byte exactly, does not call the Delegated language model, and finalizes `source_input_too_large` with its attempt ID in the failure diagnostic.
- [ ] With `SLM_NO_RECORD=1`, Source input reading stops at the processing limit, no recovery record or attempt ID is created, and the oversized failure remains explicit.
- [ ] Within-limit invalid UTF-8 Source input is retained byte-for-byte and finalized as `source_input_invalid` without a model call.
- [ ] Source input that is both oversized and invalid UTF-8 finalizes `source_input_too_large` while preserving the false UTF-8 metadata fact.
- [ ] Invalid UTF-8 Task instruction is rejected before storage is opened, an ID is allocated, or stdin is consumed.
- [ ] Read or storage-stream failures do not publish a finalized record or advertise a recoverable attempt ID.
- [ ] Tests use chunked and large finite readers to verify exact-limit behavior, complete draining, opt-out early stop, split UTF-8 sequences, invalid bytes, precedence, exact decompressed payloads, absence of model calls, diagnostics, and exit status.

## Blocked by

- [01 - Record successful Processing attempts](./01-record-successful-processing-attempts.md)
