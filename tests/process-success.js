import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

const executable = process.argv[2];
if (!executable) throw new Error("missing slm executable path");

const temporary = mkdtempSync(join(tmpdir(), "slm-process-"));
const stateDirectory = join(temporary, "state");
let requestCount = 0;

const server = Bun.serve({
  port: 0,
  async fetch(request) {
    const body = await request.json();
    requestCount += 1;
    assertEqual(body.model, "fixture-model", "effective model request");
    assertEqual(body.max_tokens, 77, "max_tokens request");
    assertEqual(request.headers.get("accept-encoding"), "gzip", "accepted encoding");

    if (requestCount === 1) {
      const response = {
        ignored: "provider field",
        choices: [
          {
            message: { content: "recorded output", refusal: null },
            finish_reason: "stop",
          },
        ],
        usage: { prompt_tokens: 9, total_tokens: 12 },
      };
      return new Response(gzipSync(JSON.stringify(response)), {
        headers: {
          "content-encoding": "gzip",
          "content-type": "application/json",
        },
      });
    }

    return Response.json({
      choices: [{ message: { content: null, refusal: "fixture refusal" } }],
    });
  },
});

try {
  const baseEnvironment = {
    OPENAI_API_KEY: "secret-that-must-not-be-recorded",
    OPENAI_BASE_URL: `http://127.0.0.1:${server.port}/v1`,
    OPENAI_MODEL: "fixture-model",
  };

  const firstSource = Buffer.from("first\nsecond\0", "utf8");
  const first = await invoke(["--max-tokens=77", "summarize"], firstSource, {
    ...baseEnvironment,
    SLM_STATE_DIR: stateDirectory,
  });
  assertEqual(first.exitCode, 0, "recorded content exit status");
  assertEqual(first.stdout, "recorded output\n", "recorded content stdout");
  assertEqual(first.stderr, "", "recorded content stderr");

  const firstRecord = readRecord(stateDirectory, "1");
  assertEqual(firstRecord.metadata.schema_version, 1, "schema version");
  assertEqual(
    firstRecord.metadata.request_format_version,
    1,
    "request format version",
  );
  assertEqual(firstRecord.metadata.attempt_id, 1, "first attempt ID");
  assertEqual(
    firstRecord.metadata.request.task_instruction,
    "summarize",
    "task instruction",
  );
  assertEqual(
    firstRecord.metadata.request.model_id,
    "fixture-model",
    "model ID",
  );
  assertEqual(
    firstRecord.metadata.request.max_tokens,
    77,
    "recorded max_tokens",
  );
  assertEqual(
    firstRecord.metadata.request.processing_byte_limit,
    16 * 1024 * 1024,
    "processing limit",
  );
  assert(
    firstRecord.metadata.request.runtime_system_prompt.length > 0,
    "runtime system prompt is present",
  );
  assert(
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(
      firstRecord.metadata.started_at_utc,
    ),
    "UTC start timestamp",
  );
  assertDurations(firstRecord.metadata.durations_ns);
  assertEqual(
    firstRecord.metadata.source_input.byte_count,
    firstSource.length,
    "source byte count",
  );
  assertEqual(
    firstRecord.metadata.source_input.utf8_valid,
    true,
    "source UTF-8 fact",
  );
  assertEqual(
    firstRecord.metadata.outcome.kind,
    "completed",
    "completed outcome",
  );
  assertEqual(
    firstRecord.metadata.outcome.model_output.kind,
    "content",
    "content output kind",
  );
  assertEqual(
    firstRecord.metadata.outcome.model_output.byte_count,
    15,
    "output byte count",
  );
  assertEqual(
    firstRecord.metadata.outcome.model_output.finish_reason,
    "stop",
    "finish reason",
  );
  assertEqual(
    firstRecord.metadata.outcome.model_output.usage.prompt_tokens,
    9,
    "prompt usage",
  );
  assertEqual(
    firstRecord.metadata.outcome.model_output.usage.total_tokens,
    12,
    "total usage",
  );
  assert(
    !("completion_tokens" in firstRecord.metadata.outcome.model_output.usage),
    "absent completion usage stays absent",
  );
  assertBytes(firstRecord.source, firstSource, "stored source input");
  assertBytes(
    firstRecord.output,
    Buffer.from("recorded output"),
    "stored model output",
  );

  const serializedMetadata = JSON.stringify(firstRecord.metadata);
  for (const excluded of [
    baseEnvironment.OPENAI_API_KEY,
    baseEnvironment.OPENAI_BASE_URL,
    "authorization",
  ]) {
    assert(
      !serializedMetadata.includes(excluded),
      `metadata excludes ${excluded}`,
    );
  }

  const optedOut = await invoke(
    ["--max-tokens=77", "summarize"],
    Buffer.from("private"),
    {
      ...baseEnvironment,
      SLM_NO_RECORD: "1",
      SLM_STATE_DIR: "relative-path-must-be-ignored",
    },
  );
  assertEqual(optedOut.exitCode, 0, "opt-out exit status");
  assertEqual(optedOut.stdout, "fixture refusal\n", "opt-out stdout");
  assertEqual(optedOut.stderr, "", "opt-out stderr");
  assertEqual(
    readdirSync(join(stateDirectory, "attempts")).length,
    1,
    "opt-out creates no record",
  );

  const invalidPolicy = await invoke(
    ["--max-tokens=77", "summarize"],
    Buffer.from("ignored"),
    {
      ...baseEnvironment,
      SLM_NO_RECORD: "true",
      SLM_STATE_DIR: join(temporary, "must-not-exist"),
    },
  );
  assert(invalidPolicy.exitCode !== 0, "invalid opt-out exits unsuccessfully");
  assertEqual(invalidPolicy.stdout, "", "invalid opt-out stdout");
  assert(
    invalidPolicy.stderr.includes("SLM_NO_RECORD must be exactly 1"),
    "invalid opt-out diagnostic",
  );
  assertEqual(requestCount, 2, "invalid opt-out does not call the model");

  const second = await invoke(
    ["--max-tokens=77", "summarize"],
    Buffer.from("again"),
    {
      ...baseEnvironment,
      SLM_STATE_DIR: stateDirectory,
    },
  );
  assertEqual(second.exitCode, 0, "recorded refusal exit status");
  assertEqual(second.stdout, "fixture refusal\n", "recorded refusal stdout");
  assertEqual(second.stderr, "", "recorded refusal stderr");

  const secondRecord = readRecord(stateDirectory, "2");
  assertEqual(secondRecord.metadata.attempt_id, 2, "sequential attempt ID");
  assertEqual(
    secondRecord.metadata.outcome.model_output.kind,
    "refusal",
    "refusal output kind",
  );
  assert(
    !("finish_reason" in secondRecord.metadata.outcome.model_output),
    "absent finish reason stays absent",
  );
  assert(
    !("usage" in secondRecord.metadata.outcome.model_output),
    "absent usage stays absent",
  );
  assertBytes(
    secondRecord.output,
    Buffer.from("fixture refusal"),
    "stored refusal output",
  );
} finally {
  server.stop(true);
  rmSync(temporary, { recursive: true, force: true });
}

/** Invokes slm with controlled streams and environment. */
async function invoke(arguments_, stdin, environment) {
  const child = Bun.spawn([executable, ...arguments_], {
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

/** Reads a finalized record using only its public JSON/gzip contract. */
function readRecord(stateDirectory_, attemptId) {
  const directory = join(stateDirectory_, "attempts", attemptId);
  return {
    metadata: JSON.parse(
      readFileSync(join(directory, "metadata.json"), "utf8"),
    ),
    source: Bun.gunzipSync(readFileSync(join(directory, "source-input.gz"))),
    output: Bun.gunzipSync(readFileSync(join(directory, "model-output.gz"))),
  };
}

/** Checks monotonic duration facts without depending on exact timing. */
function assertDurations(durations) {
  assert(durations.source_ingestion >= 0, "source duration");
  assert(durations.model_request >= 0, "model duration");
  assert(
    durations.total >= durations.source_ingestion + durations.model_request,
    "total duration covers split durations",
  );
}

/** Asserts byte-for-byte equality. */
function assertBytes(actual, expected, label) {
  assert(Buffer.from(actual).equals(expected), label);
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
