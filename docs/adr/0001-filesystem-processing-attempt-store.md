# Store processing attempts as immutable filesystem records

Store each processing attempt as an immutable directory in the per-user state directory, with versioned JSON metadata and gzip-compressed source input and model output. Allocate short sequential local IDs, stream each attempt independently through a private staging directory, and publish it atomically only after reaching a terminal outcome. This preserves large inputs without buffering or database blob handling, supports concurrent processes, and keeps `slm` dependency-free; SQLite's queryability does not justify native bindings because evaluation tooling can scan the canonical records and add a derived index later.

## Consequences

- Recording is local, enabled by default, fail-closed, and suppressible with `SLM_NO_RECORD=1`.
- Payloads, metadata, and directory changes are synced before a recorded attempt is reported as completed or its model output is emitted.
- External evaluation tools may read versioned finalized record directories directly; allocation and staging files remain private implementation details.
- Finalized records are never rewritten or pruned automatically; future evaluation annotations remain separate.
- Stale staging data is removed only after its process lock is no longer held, and allocated IDs are never reused.
