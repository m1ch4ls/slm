# PRD: Processing Attempt Storage

Status: ready-for-agent

## Problem Statement

`slm` currently consumes Source input, delegates a Task instruction to a Delegated language model, prints Model output, and then forgets the entire Processing attempt. This prevents later quality evaluation and makes Source input unrecoverable when it exceeds the 16 MiB processing limit. In the oversized case, `slm` currently stops reading at the limit, so it cannot preserve the complete upstream command output or give an agent a reliable reference to it.

## Solution

Record each Processing attempt in a local, per-user, immutable filesystem record. Stream byte-exact Source input into compressed storage while reading stdin, retain processable input in memory only up to the existing limit, and store structured request context, outcomes, and Model output for later evaluation. Give every finalized failure a short sequential attempt ID, preserve oversized Source input through EOF before reporting failure, and keep successful stdout unchanged.

Recording is enabled by default and fail-closed. A user can disable all storage access for one invocation with `SLM_NO_RECORD=1`. Finalized records use a public, versioned JSON/gzip interchange format and are durable before a Processing attempt is reported as completed or its Model output is emitted.

## User Stories

1. As an `slm` user, I want successful Processing attempts recorded automatically, so that I can evaluate Model output quality later.
2. As an `slm` user, I want failed Processing attempts recorded, so that evaluation includes failure rates rather than only successful examples.
3. As an agent invoking `slm`, I want each finalized failure to report a short decimal attempt ID, so that I can repeat the identifier reliably in later commands.
4. As an agent invoking `slm`, I want oversized Source input retained completely, so that it can be recovered instead of regenerated.
5. As a user piping a large finite stream, I want `slm` to continue reading to EOF after the processing limit is crossed, so that the stored Source input is byte-exact and complete.
6. As a user piping an unbounded stream, I want storage behavior to remain explicit, so that I understand `slm` will continue consuming input and disk until EOF or interruption.
7. As a user handling sensitive data, I want `SLM_NO_RECORD=1` to disable every storage side effect, so that no ID, metadata, payload, cleanup, or directory access occurs.
8. As a user opting out of recording, I want oversized input processing to stop at the 16 MiB limit, so that `slm` does not drain bytes it will discard.
9. As a user, I want invalid `SLM_NO_RECORD` values rejected before stdin is consumed, so that recording policy is never ambiguous.
10. As a user, I want invalid arguments, missing configuration, help, and the Agent skill command excluded from storage, so that the store contains only Processing attempts.
11. As a user, I want an invalid UTF-8 Task instruction rejected before storage starts, so that non-processable invocations do not allocate attempt IDs.
12. As a user piping arbitrary bytes, I want Source input stored byte-for-byte even when it is not UTF-8, so that recovery data is never corrupted by text conversion.
13. As a user piping invalid UTF-8 within the processing limit, I want the attempt finalized as `source_input_invalid` without a model call, so that provider behavior is deterministic.
14. As a user piping Source input that is both invalid UTF-8 and oversized, I want `source_input_too_large` to be the terminal outcome, so that the primary processing limit and recovery guidance remain visible.
15. As a user, I want empty Source input recorded consistently, so that prompt-only Processing attempts remain evaluable.
16. As an evaluator, I want the Task instruction and Source input stored separately, so that I can analyze task intent independently from source data.
17. As an evaluator, I want Source input retrieval to reproduce the original stdin bytes without wrapper tags or an added newline, so that it can be reused in pipelines exactly.
18. As an evaluator, I want Model output stored before CLI newline normalization, so that the record represents delegated model text rather than stdout presentation.
19. As an evaluator, I want normal content and refusals represented as distinct Model output kinds, so that refusals are not counted as ordinary completions.
20. As an evaluator, I want ambiguous responses containing both content and refusal rejected as `model_response_invalid`, so that output kind remains a valid discriminated state.
21. As an evaluator, I want the provider finish reason retained when present, so that truncation and filtering can be identified.
22. As an evaluator, I want optional prompt, completion, and total token counts retained when present, so that quality can be compared with token cost.
23. As an evaluator, I want missing usage values represented as absent rather than zero, so that unsupported provider metadata is not misinterpreted.
24. As an evaluator, I want the effective model ID and `max_tokens` retained, so that outputs can be grouped by generation configuration.
25. As an evaluator, I want the full Runtime system prompt retained per attempt, so that historical model-facing instructions do not depend on old source trees or binaries.
26. As an evaluator, I want request-format and schema versions retained, so that the exact model-facing message can be reconstructed after framing changes.
27. As an evaluator, I want the configured processing byte limit retained, so that oversized outcomes remain interpretable if defaults change.
28. As an evaluator, I want Source input and Model output byte counts retained, so that corpus characteristics can be measured without decompression.
29. As an evaluator, I want Source input UTF-8 validity retained as a fact, so that encoding quality can be analyzed independently from terminal outcome.
30. As an evaluator, I want UTC start time and separate source-ingestion, model-request, and total monotonic durations, so that producer latency and model latency can be distinguished.
31. As an evaluator, I want stable terminal outcome categories, so that aggregate metrics do not depend on unstable error strings.
32. As an evaluator, I want safe facts such as HTTP status or internal error name retained for failed model requests, so that failures can be grouped without storing provider response bodies.
33. As a privacy-conscious user, I want API keys, authorization headers, endpoint URLs, response bodies, stderr, current directory, argv, host identity, and environment context excluded, so that the corpus contains only intentional semantic request data.
34. As a user, I want records stored under my per-user state directory rather than the current project, so that behavior is consistent across repositories.
35. As a user, I want to relocate the store with an absolute `SLM_STATE_DIR`, so that I can choose a different volume without making storage cwd-dependent.
36. As a user, I want a relative `SLM_STATE_DIR` rejected before stdin is consumed, so that records cannot silently move between projects.
37. As a user, I want the store and payloads accessible only by my account, so that automatically captured content is not exposed to other local users.
38. As a user, I want unsafe existing store permissions rejected rather than silently accepted or changed, so that privacy failures are explicit.
39. As a user, I want storage initialization failures reported before stdin is consumed, so that a pipe is not drained without the promised record.
40. As a user, I want model processing suppressed when Source input cannot be durably recorded, so that recording mode never silently loses its input.
41. As a user, I want Model output suppressed when final persistence fails, so that a recorded-mode success always has a durable immutable record.
42. As a user, I want a completed record finalized before stdout is written, so that Model output remains recoverable if downstream output delivery fails.
43. As a user, I want stdout delivery failure excluded from the stored processing outcome, so that model quality is not conflated with downstream pipe behavior.
44. As a user, I want records and directory publication synced before success, so that completed attempts survive sudden power loss.
45. As a user running concurrent commands, I want each `slm` process to capture independently, so that a long Source input does not block unrelated Processing attempts.
46. As a user running concurrent commands, I want sequential ID allocation synchronized briefly, so that attempt IDs remain unique without serializing entire Processing attempts.
47. As an agent, I want allocated IDs never reused, so that an old failure message can never resolve to unrelated data.
48. As an operator, I want gaps in sequential IDs treated as valid, so that crashes do not require dangerous ID reclamation.
49. As an operator, I want active attempts written in private staging directories, so that evaluators never observe partial records.
50. As an operator, I want stale staging data removed only after its process lock is no longer held, so that cleanup cannot delete a concurrent active capture.
51. As an operator, I want interrupted partial gzip data hidden and discarded, so that invalid payloads cannot masquerade as finalized Source input.
52. As an evaluator, I want finalized attempt directories published atomically, so that every visible record is complete.
53. As an evaluator, I want versioned JSON metadata and standard gzip payloads, so that tooling in Python, JavaScript, and shell environments can read the corpus directly.
54. As an evaluator, I want the finalized record layout to be a supported interchange contract, so that I do not need to invoke `slm` for bulk corpus scans.
55. As a maintainer, I want allocation counters and staging artifacts excluded from the public interchange contract, so that internals can evolve without breaking evaluators.
56. As a maintainer, I want new writers to emit only the current schema while readers may support older schemas, so that compatibility is explicit.
57. As a maintainer, I want old records never rewritten automatically, so that captured evidence remains immutable.
58. As an evaluator, I want future scores and annotations stored separately from Processing attempt records, so that evaluation cannot mutate captured evidence.
59. As a user, I want gzip level 1 compression for Source input and Model output, so that indefinite local retention uses less disk without materially slowing pipelines.
60. As a user, I want no automatic pruning, so that an attempt does not disappear before evaluation or recovery.
61. As a maintainer, I want the implementation to use Zig's standard library only, so that storage does not add a native database dependency.
62. As a maintainer, I want request formatting reconstructed from versioned components rather than duplicating the complete model-facing message, so that large Source input is not stored twice.
63. As a maintainer, I want unsupported newer record schemas rejected explicitly, so that old readers do not silently misinterpret data.
64. As a user, I want successful invocations to emit no attempt ID or storage diagnostics, so that existing stdout and quiet-stderr contracts remain intact.

## Implementation Decisions

- Introduce a deep attempt-store module with a small lifecycle interface: open a secure local store, begin a Processing attempt, stream Source input, and finalize exactly one terminal outcome. The module owns path resolution, permission checks, sequential ID allocation, process locking, staging, gzip level 1 compression, JSON serialization, atomic publication, syncing, stale-staging cleanup, and immutable record layout.
- Introduce a focused streaming source-capture module that tees stdin into the attempt store, retains at most 16 MiB for model processing, counts all uncompressed bytes, validates UTF-8 across chunk boundaries, and continues to EOF in recording mode. Its result distinguishes processable text, oversized Source input, invalid Source input, and incomplete reads without exposing buffering/compression mechanics to the CLI.
- Change the delegated-completion boundary to return a structured completion rather than bare text. A completion contains exactly one output kind (`content` or `refusal`), text, optional finish reason, optional usage counts, and model-request duration. Expected failures expose stable request/response categories and bounded safe facts rather than logging raw API response bodies into storage.
- Keep the CLI entry point as a thin orchestrator. It validates arguments, UTF-8 Task instruction, model configuration, and storage environment variables before opening the store or consuming stdin; coordinates source capture, model invocation, attempt finalization, diagnostics, and stdout; and maps failures to process exit behavior.
- A Processing attempt begins only after a valid Task instruction and required configuration are available and stdin consumption starts. Help, Agent skill output, invalid arguments, invalid Task instruction, and configuration failures create no record.
- Recording is enabled when `SLM_NO_RECORD` is absent. The only accepted disabling value is exactly `1`; other present values are configuration errors. Disabled mode performs no store access and retains current bounded stdin behavior.
- Resolve the store root from an absolute `SLM_STATE_DIR` when provided, then `XDG_STATE_HOME`, then the user's home state fallback. Relative overrides are invalid. Missing usable state configuration is fatal before stdin consumption.
- New store directories use owner-only permissions and new files use owner-read/write permissions. Existing store paths with group or world access are rejected rather than modified.
- The public finalized layout is `attempts/<decimal-id>/metadata.json`, `source-input.gz`, and `model-output.gz` when Model output exists. Staging directories, allocation state, and locks are private.
- Attempt IDs are monotonically increasing local decimal integers. Allocation is synchronized independently of attempt capture; IDs may have gaps and are never reused.
- Each active attempt holds a process lock associated with private staging. Cleanup removes staging only when that lock can no longer be held by an active process. Interrupted records are not published.
- Files, metadata, renamed attempt directories, allocation state, and relevant parent directories are synced as required for power-loss durability before finalization is acknowledged.
- Finalized Processing attempt records are immutable. The writer never edits or prunes them, and future evaluation annotations must use separate records keyed by attempt ID.
- Metadata is UTF-8 JSON with explicit schema and request-format versions. Source input and Model output are gzip level 1 streams whose decompressed bytes exactly match the captured values.
- Metadata contains the attempt ID, UTC start time, source-ingestion/model-request/total monotonic durations, Task instruction, full Runtime system prompt, effective model ID, `max_tokens`, processing byte limit, Source input byte count and UTF-8 fact, terminal outcome, and category-specific safe facts. Completed outcomes also contain Model output kind and byte count, optional finish reason, and optional usage counts.
- Endpoint URLs, API credentials, headers, raw API exchanges, response bodies, stderr, full argv, current directory, hostname, username, and unrelated environment values are never persisted.
- Request-format versions define how Task instruction and Source input become the model-facing user message. The formatted message is reconstructed rather than stored as a duplicate payload.
- Stable terminal outcomes are `completed`, `source_input_too_large`, `source_input_invalid`, `model_request_failed`, and `model_response_invalid`.
- When Source input exceeds 16 MiB in recording mode, `slm` continues capture through EOF, does not call the Delegated language model, durably finalizes `source_input_too_large`, and prints the attempt ID in the failure diagnostic.
- When Source input is within the limit but invalid UTF-8, `slm` durably finalizes `source_input_invalid` without a model call. When both size and encoding fail, `source_input_too_large` is the outcome and UTF-8 validity remains metadata.
- Model request failures include network failures and non-success HTTP responses, differentiated through safe structured facts. Malformed JSON, missing choices/output, oversized response bodies, and ambiguous content/refusal responses are model-response failures.
- A successful model result is stored and finalized before stdout. The stored Model output excludes the CLI-added trailing newline. Downstream stdout failure may change process exit behavior but does not change the finalized `completed` outcome.
- If storage fails while recording is enabled, processing fails closed. A pre-input failure consumes no stdin; a source-capture failure produces no finalized record; a post-model finalization failure suppresses Model output. The diagnostic may direct the user to opt out explicitly on a later invocation.
- Finalized failures print their attempt IDs. Completed attempts produce no additional stdout or stderr, preserving existing pipeline behavior.
- Records are retained indefinitely. Storage quotas, age limits, and automatic pruning are not introduced.
- Writers emit only the current schema version and never rewrite existing records. Future readers may support known older versions and must reject unknown newer versions explicitly; building such a reader is not required by this storage slice.
- The filesystem architecture and its consequences are governed by the accepted processing-attempt-store ADR.

## Testing Decisions

- Good tests assert externally observable contracts: finalized files and decompressed bytes, metadata semantics, process output and exit behavior, concurrency guarantees, permission failures, and model protocol interpretation. Tests must not assert private helper calls, staging names, lock implementation, buffer sizes, or incidental JSON field order.
- Test the attempt-store module in isolation against temporary directories. Cover XDG/override resolution, absolute-path validation, secure creation, unsafe existing permissions, sequential allocation, permanent gaps, concurrent allocation, independent concurrent writes, atomic visibility, gzip round trips, immutable finalization, stale-versus-active staging cleanup, schema output, and injected write/sync failures.
- Test the streaming source-capture module in isolation with chunked readers and a recording sink. Cover empty input, exact-limit input, one-byte-over-limit input, very large finite input, invalid UTF-8 split across chunk boundaries, size/encoding precedence, byte counts, complete draining in recording mode, early stop when recording is disabled, and read/write failure propagation.
- Test the delegated-completion module with protocol fixtures. Cover content, refusal, finish reason, optional/absent usage, unknown response fields, empty choices, missing output, both content and refusal, malformed JSON, non-success status, oversized response body, and safe failure facts. Raw provider bodies and credentials must never enter returned storage data.
- Test the CLI lifecycle end to end with isolated process environment, temporary state roots, deterministic stdin, and a controlled local OpenAI-compatible test endpoint. Cover excluded non-attempt commands, default recording, complete opt-out, configuration-before-storage ordering, completed output, failure diagnostics with IDs, oversized draining, invalid Source input, fail-closed storage behavior, stdout newline behavior, and no successful stderr noise.
- Test power-loss durability boundaries through observable sync-failure injection rather than attempting to simulate actual power loss. A finalization sync failure must prevent publication/success and suppress Model output.
- Test public-layout compatibility by reading finalized metadata with the schema reader and decompressing payloads using standard gzip tooling or an independent decoder where practical.
- Test that every emitted metadata record carries the current schema and request-format versions and conforms to the public discriminated outcome shape. Reader compatibility tests are deferred until a reader exists.
- Retain the repository's existing Zig unit-test style for pure parsing and formatting behavior, and extend the build-level executable test pattern already used for the Agent skill command for CLI contracts.
- No tests are required for future retrieval, listing, deletion, export, migration, evaluation scoring, or annotation behavior because those features are outside this PRD.

## Out of Scope

- Retrieving Source input or Model output through new CLI commands, including the final syntax of `--get-input` or equivalent.
- Listing, searching, filtering, or inspecting Processing attempts through `slm`.
- Deleting individual records, clearing the store, automatic pruning, quotas, age-based retention, or storage-usage reporting.
- Quality evaluation algorithms, scoring, baselines, dataset selection, human review, or model-based judging.
- Writing or managing evaluation annotations.
- Exporting, importing, synchronizing, or uploading records.
- Remote or shared storage services.
- Application-level encryption, keyring integration, or passphrase management.
- Automatic schema migrations or rewriting existing records.
- A derived query index or database.
- Recording help, Agent skill output, invalid invocation/configuration failures, stdout, stderr, endpoint URLs, credentials, ambient process context, or raw HTTP exchanges.
- Changing the 16 MiB Source input processing limit or the model API response-size limit beyond classifying their outcomes.
- Retrying model requests or recording multiple model-request attempts within one Processing attempt.

## Further Notes

- The present CLI reads stdin into a single allocation capped at 16 MiB and loses all data when that read exceeds the limit. Implementation must replace this with streaming capture before model invocation.
- The present delegated-completion boundary returns only text, discards finish reason and usage, conflates refusal with content, and logs non-success response bodies. Structured completion/outcome data is required before the store can represent the agreed schema safely.
- Zig 0.16 provides streaming gzip compression and decompression through the standard library. Its zstd support is decompression-only, which is why gzip is the interchange format.
- Compression reduces typical text storage but does not bound indefinite retention. Disk exhaustion remains an explicit fail-closed storage error.
- A future retrieval feature can stream-decompress `source-input.gz` by decimal attempt ID and emit byte-exact Source input without changing the record format.
