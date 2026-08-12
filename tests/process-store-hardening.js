import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const executable = process.argv[2];
if (!executable) throw new Error("missing slm executable path");

const temporary = mkdtempSync(join(tmpdir(), "slm-store-hardening-"));
const stateDirectory = join(temporary, "state");
let requestCount = 0;

const server = Bun.serve({
  port: 0,
  async fetch(request) {
    const body = await request.json();
    requestCount += 1;
    return Response.json({
      choices: [{ message: { content: `output:${body.messages[1].content}` } }],
    });
  },
});

const environment = {
  SLM_BASE_URL: `http://127.0.0.1:${server.port}/v1`,
  SLM_MODEL: "fixture-model",
  SLM_STATE_DIR: stateDirectory,
};

try {
  const active = Bun.spawn([executable, "process"], {
    env: environment,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  active.stdin.write("active");
  await waitFor(() => existsSync(join(stateDirectory, ".staging", "1", ".lock")));

  const concurrent = await withTimeout(
    invoke(Buffer.from("concurrent"), environment),
    2_000,
    "concurrent capture was blocked by an active attempt",
  );
  assertEqual(concurrent.exitCode, 0, "concurrent exit status");
  assert(existsSync(recordPath(2)), "concurrent process allocated ID 2");
  assert(!existsSync(recordPath(1)), "active attempt is not publicly visible");
  assert(
    existsSync(join(stateDirectory, ".staging", "1", ".lock")),
    "cleanup preserves active staging",
  );

  active.stdin.end();
  const activeResult = await collect(active);
  assertEqual(activeResult.exitCode, 0, "active exit status");
  assert(existsSync(recordPath(1)), "active attempt publishes after completion");

  const staleDirectory = join(stateDirectory, ".staging", "99");
  mkdirSync(staleDirectory);
  writeFileSync(join(staleDirectory, ".lock"), "");
  const afterCleanup = await invoke(Buffer.from("cleanup"), environment);
  assertEqual(afterCleanup.exitCode, 0, "stale cleanup exit status");
  assert(!existsSync(staleDirectory), "stale staging is removed");
  assert(existsSync(recordPath(3)), "stale staging ID is not allocated");

  const captureFailure = await invoke(Buffer.from("capture failure"), {
    ...environment,
    SLM_TEST_STORAGE_FAILURE: "capture_sync",
  });
  assertFailure(captureFailure, "capture sync failure");
  assert(!existsSync(recordPath(4)), "capture failure publishes no record");

  const finalFailure = await invoke(Buffer.from("final failure"), {
    ...environment,
    SLM_TEST_STORAGE_FAILURE: "final_sync",
  });
  assertFailure(finalFailure, "final sync failure");
  assert(!existsSync(recordPath(5)), "final sync failure publishes no record");

  const publicationFailure = await invoke(Buffer.from("publication failure"), {
    ...environment,
    SLM_TEST_STORAGE_FAILURE: "publication_sync",
  });
  assertFailure(publicationFailure, "publication sync failure");
  assert(!existsSync(recordPath(6)), "publication sync failure publishes no record");

  const publishedFailure = await invoke(Buffer.from("published sync failure"), {
    ...environment,
    SLM_TEST_STORAGE_FAILURE: "published_sync",
  });
  assertFailure(publishedFailure, "published-directory sync failure");
  verifyPublicRecord(7);

  const afterGaps = await invoke(Buffer.from("after gaps"), environment);
  assertEqual(afterGaps.exitCode, 0, "post-gap exit status");
  assert(existsSync(recordPath(8)), "allocated IDs are not reused after failures");

  const closedStdout = await invokeWithClosedStdout(Buffer.from("closed stdout"));
  assert(closedStdout.exitCode !== 0, "closed stdout exits unsuccessfully");
  assert(existsSync(recordPath(9)), "completed record precedes stdout delivery");
  const closedMetadata = readMetadata(9);
  assertEqual(closedMetadata.outcome.kind, "completed", "stdout does not alter outcome");

  unlinkSync(join(stateDirectory, ".next-id"));
  const recovered = await invoke(Buffer.from("recovered counter"), environment);
  assertEqual(recovered.exitCode, 0, "allocation recovery exit status");
  assert(existsSync(recordPath(10)), "allocation recovery never reuses an ID");

  const unsafeDirectory = join(temporary, "unsafe-state");
  mkdirSync(unsafeDirectory);
  chmodSync(unsafeDirectory, 0o755);
  const rejected = Bun.spawn([executable, "process"], {
    env: { ...environment, SLM_STATE_DIR: unsafeDirectory },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  const rejectedResult = await withTimeout(
    collect(rejected),
    2_000,
    "unsafe store initialization tried to consume stdin",
  );
  assert(rejectedResult.exitCode !== 0, "unsafe store is rejected");

  for (const id of [1, 2, 3, 7, 8, 9, 10]) verifyPublicRecord(id);
  assertEqual(requestCount, 9, "only processable Source input reaches the model");
} finally {
  server.stop(true);
  rmSync(temporary, { recursive: true, force: true });
}

/** Invokes slm with controlled byte input. */
async function invoke(stdin, environment_) {
  const child = Bun.spawn([executable, "process"], {
    env: environment_,
    stdin,
    stdout: "pipe",
    stderr: "pipe",
  });
  return collect(child);
}

/** Invokes slm after closing its stdout descriptor. */
async function invokeWithClosedStdout(stdin) {
  const child = Bun.spawn([
    "bash",
    "-c",
    'exec 1>&-; exec "$1" process',
    "bash",
    executable,
  ], {
    env: environment,
    stdin,
    stdout: "pipe",
    stderr: "pipe",
  });
  return collect(child);
}

/** Collects process outputs. */
async function collect(child) {
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  return { exitCode, stdout, stderr };
}

/** Reads a record as an external evaluator using only JSON and gzip. */
function verifyPublicRecord(id) {
  const directory = recordPath(id);
  assertEqual(
    readdirSync(directory).sort().join(","),
    "metadata.json,model-output.gz,source-input.gz",
    `public files for attempt ${id}`,
  );
  const metadata = readMetadata(id);
  assertEqual(metadata.schema_version, 1, `schema for attempt ${id}`);
  assertEqual(metadata.request_format_version, 1, `request format for attempt ${id}`);
  assertEqual(metadata.attempt_id, id, `metadata ID for attempt ${id}`);
  Bun.gunzipSync(readFileSync(join(directory, "source-input.gz")));
  const output = Bun.gunzipSync(readFileSync(join(directory, "model-output.gz")));
  assertEqual(output.length, metadata.outcome.model_output.byte_count, "output byte count");
}

/** Reads public metadata without using store implementation code. */
function readMetadata(id) {
  return JSON.parse(readFileSync(join(recordPath(id), "metadata.json"), "utf8"));
}

/** Returns a finalized attempt path. */
function recordPath(id) {
  return join(stateDirectory, "attempts", String(id));
}

/** Waits for an observable filesystem condition. */
async function waitFor(predicate) {
  for (let index = 0; index < 200; index += 1) {
    if (predicate()) return;
    await Bun.sleep(10);
  }
  throw new Error("timed out waiting for filesystem state");
}

/** Bounds a concurrency assertion. */
async function withTimeout(promise, milliseconds, message) {
  return Promise.race([
    promise,
    Bun.sleep(milliseconds).then(() => {
      throw new Error(message);
    }),
  ]);
}

/** Verifies fail-closed output behavior. */
function assertFailure(result, label) {
  assert(result.exitCode !== 0, `${label} exit status`);
  assertEqual(result.stdout, "", `${label} stdout suppression`);
  assert(result.stderr.includes("InjectedStorageFailure"), `${label} diagnostic`);
}

/** Asserts strict value equality. */
function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(
      `${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

/** Asserts a condition. */
function assert(condition, label) {
  if (!condition) throw new Error(label);
}
