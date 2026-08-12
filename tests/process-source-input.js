import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const executable = process.argv[2];
if (!executable) throw new Error("missing slm executable path");

const temporary = mkdtempSync(join(tmpdir(), "slm-source-input-"));
const stateDirectory = join(temporary, "state");
const processingLimit = 16 * 1024 * 1024;
let requestCount = 0;

const server = Bun.serve({
  port: 0,
  fetch() {
    requestCount += 1;
    return Response.json({
      choices: [{ message: { content: "processed" } }],
    });
  },
});

const environment = {
  SLM_BASE_URL: `http://127.0.0.1:${server.port}/v1`,
  SLM_MODEL: "fixture-model",
  SLM_STATE_DIR: stateDirectory,
};

try {
  const exact = Buffer.alloc(processingLimit, 0x61);
  const exactResult = await invoke(exact, environment);
  assertEqual(exactResult.exitCode, 0, "exact-limit exit status");
  assertEqual(exactResult.stdout, "processed\n", "exact-limit output");
  assertEqual(requestCount, 1, "exact-limit model call");
  assertRecord(stateDirectory, 1, exact, true, "completed");

  const oversized = Buffer.concat([
    Buffer.alloc(processingLimit, 0x62),
    Buffer.from("complete trailing bytes"),
  ]);
  const oversizedResult = await invoke(oversized, environment);
  assertFailure(
    oversizedResult,
    "slm: source input too large (attempt 2)\n",
  );
  assertEqual(requestCount, 1, "oversized input skips model");
  assertRecord(
    stateDirectory,
    2,
    oversized,
    true,
    "source_input_too_large",
  );

  const invalid = Buffer.from([0x61, 0xe2, 0x28, 0xa1, 0x62]);
  const invalidResult = await invoke(invalid, environment);
  assertFailure(
    invalidResult,
    "slm: source input is not valid UTF-8 (attempt 3)\n",
  );
  assertEqual(requestCount, 1, "invalid input skips model");
  assertRecord(stateDirectory, 3, invalid, false, "source_input_invalid");

  const oversizedInvalid = Buffer.concat([
    Buffer.from([0xff]),
    Buffer.alloc(processingLimit, 0x63),
  ]);
  const precedenceResult = await invoke(oversizedInvalid, environment);
  assertFailure(
    precedenceResult,
    "slm: source input too large (attempt 4)\n",
  );
  assertRecord(
    stateDirectory,
    4,
    oversizedInvalid,
    false,
    "source_input_too_large",
  );
  assertEqual(requestCount, 1, "oversized invalid input skips model");

  const optedOutDirectory = join(temporary, "opted-out");
  const optedOut = await invoke(Buffer.alloc(processingLimit + 1, 0x64), {
    ...environment,
    SLM_NO_RECORD: "1",
    SLM_STATE_DIR: optedOutDirectory,
  });
  assertFailure(optedOut, "slm: source input too large\n");
  assert(!existsSync(optedOutDirectory), "opt-out creates no store");
  assertEqual(requestCount, 1, "opt-out oversized input skips model");

  const invalidTaskDirectory = join(temporary, "invalid-task");
  const invalidTask = await invokeInvalidTask(invalidTaskDirectory);
  assertFailure(
    invalidTask,
    "slm: task instruction is not valid UTF-8\n",
  );
  assert(!existsSync(invalidTaskDirectory), "invalid task creates no store");
  assertEqual(requestCount, 1, "invalid task skips model");
} finally {
  server.stop(true);
  rmSync(temporary, { recursive: true, force: true });
}

/** Invokes slm with byte-exact stdin. */
async function invoke(stdin, environment_) {
  const child = Bun.spawn([executable, "process"], {
    env: environment_,
    stdin,
    stdout: "pipe",
    stderr: "pipe",
  });
  return collect(child);
}

/** Uses bash ANSI quoting to pass an argv byte that is not valid UTF-8. */
async function invokeInvalidTask(stateDirectory_) {
  const child = Bun.spawn([
    "bash",
    "-c",
    `exec "$1" $'\\xff'`,
    "bash",
    executable,
  ], {
    env: { SLM_STATE_DIR: stateDirectory_ },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  let timeout;
  try {
    return await Promise.race([
      collect(child),
      new Promise((_, reject) => {
        timeout = setTimeout(() => {
          child.kill();
          reject(new Error("invalid Task instruction tried to consume stdin"));
        }, 2_000);
      }),
    ]);
  } finally {
    clearTimeout(timeout);
  }
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

/** Reads and verifies an unprocessable Source input record. */
function assertRecord(
  stateDirectory_,
  id,
  expectedSource,
  utf8Valid,
  outcome,
) {
  const directory = join(stateDirectory_, "attempts", String(id));
  const metadata = JSON.parse(
    readFileSync(join(directory, "metadata.json"), "utf8"),
  );
  const source = Bun.gunzipSync(
    readFileSync(join(directory, "source-input.gz")),
  );
  assertEqual(metadata.source_input.byte_count, expectedSource.length, "byte count");
  assertEqual(metadata.source_input.utf8_valid, utf8Valid, "UTF-8 fact");
  assertEqual(metadata.outcome.kind, outcome, "outcome");
  assert(Buffer.from(source).equals(expectedSource), "exact retained Source input");
  if (outcome !== "completed") {
    assert(!existsSync(join(directory, "model-output.gz")), "no model output");
    assertEqual(metadata.durations_ns.model_request, 0, "no model duration");
  }
}

/** Verifies a source rejection process contract. */
function assertFailure(result, diagnostic) {
  assert(result.exitCode !== 0, "failure exit status");
  assertEqual(result.stdout, "", "failure stdout");
  assertEqual(result.stderr, diagnostic, "failure diagnostic");
}

/** Asserts strict equality. */
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
