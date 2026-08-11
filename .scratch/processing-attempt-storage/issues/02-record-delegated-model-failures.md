# Record Delegated language model failures

Status: ready-for-agent
Execution: AFK

## What to build

Extend the Processing attempt lifecycle through every terminal Delegated language model failure. Network and non-success HTTP failures become `model_request_failed`; malformed, missing, oversized, or semantically ambiguous completion responses become `model_response_invalid`. Each failure durably retains the already captured Source input, stores only bounded safe facts, emits no Model output, and reports its attempt ID to stderr.

## Acceptance criteria

- [ ] Network failures and non-success HTTP statuses finalize `model_request_failed` records with stable safe facts that distinguish the failure without persisting credentials, endpoint URLs, response bodies, or raw transport data.
- [ ] Malformed JSON, empty choices, missing output, oversized response bodies, and responses containing both non-null content and refusal finalize `model_response_invalid` records.
- [ ] Every finalized model failure retains byte-exact Source input and the same semantic request metadata captured for a completed attempt, but has no Model output payload.
- [ ] Every finalized failure prints its decimal attempt ID in a concise stderr diagnostic, emits no stdout, and exits unsuccessfully.
- [ ] Completion parsing makes content/refusal an impossible ambiguous state rather than silently preferring either field.
- [ ] Protocol tests cover content, refusal, optional finish reason/usage, unknown response fields, all model-response-invalid cases, HTTP failure, and network failure using owned fixtures or a controlled local OpenAI-compatible endpoint.
- [ ] Process-level tests verify the visible record, outcome, safe facts, diagnostics, streams, and exit status without depending on internal error plumbing.

## Blocked by

- [01 - Record successful Processing attempts](./01-record-successful-processing-attempts.md)
