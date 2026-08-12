import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [executable] = process.argv.slice(2);
if (!executable) throw new Error("missing slm executable path");

const temporary = mkdtempSync(join(tmpdir(), "slm-config-"));
try {
  const automatic = await invoke({
    OPENAI_API_KEY: "openai-secret",
    GEMINI_API_KEY: "gemini-secret",
    SLM_STATE_DIR: temporary,
  });
  assertEqual(automatic.exitCode, 0, "automatic exit");
  assertIncludes(automatic.stdout, "mode: automatic\n", "automatic mode");
  assertIncludes(automatic.stdout, "provider: OpenAI\n", "cheapest provider");
  assertIncludes(automatic.stdout, "model: gpt-5-nano\n", "selected model");
  assertIncludes(automatic.stdout, "authentication: OPENAI_API_KEY\n", "credential name");
  assert(!automatic.stdout.includes("openai-secret"), "credential value excluded");

  const explicit = await invoke({
    SLM_BASE_URL: "http://localhost:11434/v1",
    SLM_MODEL: "local-model",
    SLM_API_KEY: "local-secret",
  });
  assertEqual(explicit.exitCode, 0, "explicit exit");
  assertIncludes(explicit.stdout, "mode: explicit\n", "explicit mode");
  assertIncludes(explicit.stdout, "provider: unknown\n", "unknown provider");
  assert(!explicit.stdout.includes("local-secret"), "explicit secret excluded");

  const invalid = await invoke({ GEMINI_API_KEY: "" });
  assertEqual(invalid.exitCode, 1, "invalid exit");
  assertIncludes(invalid.stdout, "status: invalid\n", "invalid status");
  assertEqual(invalid.stderr, "", "invalid stderr");
} finally {
  rmSync(temporary, { recursive: true, force: true });
}

async function invoke(environment) {
  const child = Bun.spawn([executable, "--debug-config"], {
    env: environment,
    stdin: "pipe",
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

function assertIncludes(actual, expected, label) {
  if (!actual.includes(expected)) throw new Error(`${label}: missing ${JSON.stringify(expected)} in ${JSON.stringify(actual)}`);
}

function assert(condition, label) {
  if (!condition) throw new Error(label);
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
