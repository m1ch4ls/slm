# Make the Processing attempt store durable, concurrent, and public

Status: ready-for-agent
Execution: AFK

## What to build

Harden every terminal Processing attempt path behind one fail-closed publication boundary and complete the store as a supported public interchange format. Active attempts remain private until payloads, metadata, rename operations, allocation state, and relevant directories are synced. Concurrent processes allocate IDs briefly under synchronization and then capture independently. Interrupted staging is removed only after proving its process lock is no longer active.

Document and independently verify the immutable versioned JSON/gzip record contract so evaluation tools can scan finalized attempts directly without depending on allocation or staging internals.

## Acceptance criteria

- [ ] No finalized record becomes visible until all required payload and metadata writes are complete, and successful completion is not acknowledged until file and directory state is synced for power-loss durability.
- [ ] Storage initialization failure occurs before stdin consumption; source-capture failure publishes no record; post-model persistence or sync failure suppresses Model output and exits unsuccessfully.
- [ ] A finalized `completed` outcome is established before stdout delivery, and a downstream stdout failure does not mutate that processing outcome.
- [ ] Finalized records are immutable, are never automatically pruned or rewritten, and future evaluation annotations are explicitly outside the record and keyed separately by attempt ID.
- [ ] Multiple processes can allocate unique sequential decimal IDs and capture concurrently without holding a store-wide lock for the Processing attempt lifetime.
- [ ] Allocated IDs may have permanent gaps after interruption and are never reused, including after allocation-state recovery.
- [ ] Active staging remains untouched by cleanup; staging whose process lock is no longer held is removed safely; no partial gzip payload is exposed as a finalized record.
- [ ] The finalized versioned metadata and gzip payload layout is documented as the public interchange contract, while counters, locks, and staging remain private.
- [ ] Writers emit only the current schema and request-format versions and never rewrite existing records; future readers are required to reject unknown newer schemas explicitly.
- [ ] Independent compatibility verification parses emitted metadata and decompresses payloads without relying on private store implementation details.
- [ ] Concurrent process tests verify uniqueness and non-blocking capture; failure-injection tests verify write/sync suppression and atomic visibility; stale/active staging tests verify lock-sensitive cleanup.

## Blocked by

- [02 - Record Delegated language model failures](./02-record-delegated-model-failures.md)
- [03 - Record unprocessable Source input](./03-record-unprocessable-source-input.md)
