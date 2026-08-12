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

const temporary = mkdtempSync(join(tmpdir(), "slm-failures-"));
const stateDirectory = join(temporary, "state");
let responseIndex = 0;

const responses = [
  () => new Response("{"),
  () => Response.json({ choices: [] }),
  () => Response.json({ choices: [{ message: {} }] }),
  () =>
    Response.json({
      choices: [{ message: { content: "answer", refusal: "no" } }],
    }),
  () => new Response("x".repeat(16 * 1024 * 1024 + 1)),
  () => new Response("secret provider body", { status: 429 }),
];

const server = Bun.serve({
  port: 0,
  fetch() {
    const response = responses[responseIndex];
    responseIndex += 1;
    if (!response) throw new Error("unexpected model request");
    return response();
  },
});

const baseEnvironment = {
  SLM_API_KEY: "secret-api-key",
  SLM_BASE_URL: `http://127.0.0.1:${server.port}/v1`,
  SLM_MODEL: "fixture-model",
  SLM_STATE_DIR: stateDirectory,
};

try {
  const invalidCases = [
    "malformed_json",
    "empty_choices",
    "missing_output",
    "ambiguous_output",
    "response_too_large",
  ];

  for (const [index, reason] of invalidCases.entries()) {
    const id = index + 1;
    const source = Buffer.from(`source-${reason}\0`);
    const result = await invoke(source, baseEnvironment);
    assertFailureProcess(result, id, "invalid model response");

    const record = readFailureRecord(stateDirectory, id);
    assertCommonRecord(record, id, source);
    assertEqual(record.metadata.outcome.kind, "model_response_invalid", "invalid outcome");
    assertEqual(record.metadata.outcome.reason, reason, "invalid reason");
  }

  const httpSource = Buffer.from("http source");
  const http = await invoke(httpSource, baseEnvironment);
  assertFailureProcess(http, 6, "model request failed");
  const httpRecord = readFailureRecord(stateDirectory, 6);
  assertCommonRecord(httpRecord, 6, httpSource);
  assertEqual(httpRecord.metadata.outcome.kind, "model_request_failed", "HTTP outcome");
  assertEqual(httpRecord.metadata.outcome.failure.kind, "http_status", "HTTP failure kind");
  assertEqual(httpRecord.metadata.outcome.failure.http_status, 429, "HTTP status");
  assert(!JSON.stringify(httpRecord.metadata).includes("secret provider body"), "HTTP body excluded");

  const stoppedPort = server.port;
  server.stop(true);
  const networkSource = Buffer.from("network source");
  const network = await invoke(networkSource, {
    ...baseEnvironment,
    SLM_BASE_URL: `http://127.0.0.1:${stoppedPort}/v1`,
  });
  assertFailureProcess(network, 7, "model request failed");
  const networkRecord = readFailureRecord(stateDirectory, 7);
  assertCommonRecord(networkRecord, 7, networkSource);
  assertEqual(networkRecord.metadata.outcome.kind, "model_request_failed", "network outcome");
  assertEqual(networkRecord.metadata.outcome.failure.kind, "network", "network failure kind");
  assert(
    typeof networkRecord.metadata.outcome.failure.error_name === "string" &&
      networkRecord.metadata.outcome.failure.error_name.length > 0 &&
      networkRecord.metadata.outcome.failure.error_name.length < 128,
    "bounded network error name",
  );

  const serialized = JSON.stringify(networkRecord.metadata);
  for (const excluded of [
    baseEnvironment.SLM_API_KEY,
    baseEnvironment.SLM_BASE_URL,
    "authorization",
  ]) {
    assert(!serialized.includes(excluded), `metadata excludes ${excluded}`);
  }
} finally {
  server.stop(true);
  rmSync(temporary, { recursive: true, force: true });
}

/** Invokes slm against the controlled endpoint. */
async function invoke(stdin, environment) {
  const child = Bun.spawn([executable, "--max-tokens=77", "summarize"], {
    env: environment,
    stdin,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  return { exitCode, stdout, stderr };
}

/** Verifies the process contract for a finalized model failure. */
function assertFailureProcess(result, id, diagnostic) {
  assert(result.exitCode !== 0, "failure exit status");
  assertEqual(result.stdout, "", "failure stdout");
  assertEqual(result.stderr, `slm: ${diagnostic} (attempt ${id})\n`, "failure diagnostic");
}

/** Reads a failure record through the public JSON/gzip layout. */
function readFailureRecord(stateDirectory_, id) {
  const directory = join(stateDirectory_, "attempts", String(id));
  assert(!existsSync(join(directory, "model-output.gz")), "failure has no model output");
  return {
    metadata: JSON.parse(readFileSync(join(directory, "metadata.json"), "utf8")),
    source: Bun.gunzipSync(readFileSync(join(directory, "source-input.gz"))),
  };
}

/** Verifies request metadata and exact retained Source input. */
function assertCommonRecord(record, id, source) {
  assertEqual(record.metadata.attempt_id, id, "attempt ID");
  assertEqual(record.metadata.request.task_instruction, "summarize", "task instruction");
  assertEqual(record.metadata.request.model_id, "fixture-model", "model ID");
  assertEqual(record.metadata.request.max_tokens, 77, "max_tokens");
  assert(record.metadata.request.runtime_system_prompt.length > 0, "system prompt");
  assert(record.metadata.durations_ns.model_request >= 0, "model duration");
  assertEqual(record.metadata.source_input.byte_count, source.length, "source byte count");
  assertEqual(record.metadata.source_input.utf8_valid, true, "source UTF-8 fact");
  assert(Buffer.from(record.source).equals(source), "exact Source input");
}

/** Asserts strict value equality. */
function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

/** Asserts a condition. */
function assert(condition, label) {
  if (!condition) throw new Error(label);
}
