# Processing attempt record format

Finalized Processing attempts are immutable public interchange records under the
per-user state directory. Evaluation tools may scan `attempts/` directly without
invoking `slm` or reading private allocation and staging state.

## Layout

```text
attempts/<decimal-id>/
  metadata.json
  source-input.gz
  model-output.gz  # completed outcomes only
```

`<decimal-id>` is an unsigned base-10 integer without padding. IDs increase
monotonically but may contain permanent gaps. A directory appears atomically only
after its payloads and metadata are complete. Records are never rewritten, reused,
or automatically pruned.

Files outside `attempts/`, including dotfiles, counters, locks, and staging
directories, are private implementation details and must not be consumed by
evaluation tools. Future annotations and scores must be stored separately and keyed
by attempt ID; they are not fields added to a finalized record.

## Payloads

`source-input.gz` and `model-output.gz` are standard gzip streams written at
compression level 1. Decompressing `source-input.gz` yields the exact Source input
bytes. Decompressing `model-output.gz` yields the exact delegated Model output before
CLI newline normalization. Failure outcomes do not have `model-output.gz`.

## Metadata version 1

`metadata.json` is UTF-8 JSON with this common shape:

```json
{
  "schema_version": 1,
  "request_format_version": 1,
  "attempt_id": 42,
  "started_at_utc": "2026-08-11T12:34:56.789Z",
  "durations_ns": {
    "source_ingestion": 100,
    "model_request": 200,
    "total": 300
  },
  "request": {
    "task_instruction": "summarize",
    "runtime_system_prompt": "...",
    "provider": "openai",
    "model_id": "model-name",
    "max_tokens": 16384,
    "processing_byte_limit": 16777216
  },
  "source_input": {
    "byte_count": 123,
    "utf8_valid": true
  },
  "outcome": { "kind": "completed" }
}
```

Durations are unsigned monotonic nanoseconds. `started_at_utc` is an RFC 3339 UTC
timestamp with millisecond precision. Byte counts are uncompressed byte lengths.
`provider` is present for automatic selection and omitted for explicit configuration;
endpoint and credential details are never recorded.

`outcome.kind` is the discriminator and has one of these shapes:

- `completed`: `model_output` contains `kind` (`content` or `refusal`) and
  `byte_count`. It may contain `finish_reason` and `usage`; `usage` may contain
  `prompt_tokens`, `completion_tokens`, and `total_tokens` independently.
- `source_input_too_large`: no additional fields.
- `source_input_invalid`: no additional fields.
- `model_request_failed`: `failure.kind` is `network` with `error_name`, or
  `http_status` with `http_status`.
- `model_response_invalid`: `reason` is `malformed_json`, `empty_choices`,
  `missing_output`, `response_too_large`, or `ambiguous_output`.

Absent optional facts are omitted rather than encoded as `null` or zero. Consumers
must select a decoder by `schema_version` and explicitly reject unknown newer schema
versions. Request reconstruction likewise requires a supported
`request_format_version`; version 1 combines the recorded Task instruction and
decompressed Source input according to the version-1 request framing implemented by
`slm`. Writers emit only the current schema and request-format versions.
