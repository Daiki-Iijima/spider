import { spawn } from "node:child_process";
import { once } from "node:events";
import { lstat, mkdtemp, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";

export type Provider = "codex" | "claude";

const CODEX_CONFIG = [
  "-c", 'cli_auth_credentials_store="auto"',
  "-c", 'model_provider="openai"',
  "-c", "project_root_markers=[]",
];
const CODEX_EXEC = [
  "exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check",
  "--sandbox", "read-only", "--json", "--color", "never", ...CODEX_CONFIG,
  "-c", 'forced_login_method="chatgpt"',
  "-c", 'approval_policy="never"',
  "-c", 'approvals_reviewer="user"',
  "-c", 'web_search="disabled"',
  "-c", "project_doc_max_bytes=0",
  ...[
    "shell_tool", "shell_snapshot", "hooks", "plugins", "remote_plugin", "apps",
    "browser_use", "browser_use_external", "computer_use", "multi_agent", "multi_agent_v2",
    "image_generation", "view_image", "goals", "fast_mode", "skill_mcp_dependency_install",
  ].flatMap((feature) => ["--disable", feature]),
  "-",
];

// Safe mode preserves saved login credentials, unlike --bare. Admin policy still applies.
const CLAUDE_SETTINGS = [
  "--safe-mode", "--setting-sources", "",
  "--settings", '{"disableAllHooks":true,"forceLoginMethod":"claudeai"}',
];
const CLAUDE_PRINT = [
  "--print", ...CLAUDE_SETTINGS, "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
  "--tools", "", "--no-session-persistence", "--no-chrome", "--disable-slash-commands",
  "--permission-mode", "dontAsk", "--output-format", "json",
  "--system-prompt", "You are a helpful conversational assistant. Respond directly to the conversation provided.",
];
const CLAUDE_PLANS = ["pro", "max", "ultra", "team", "enterprise"];

const DISPLAY_NAME: Record<Provider, string> = { codex: "Codex", claude: "Claude Code" };
const LOGIN_HELP: Record<Provider, string> = {
  codex: "Sign in with your ChatGPT account using `codex login` (not an API key).",
  claude: "Sign in with your Claude subscription using `claude auth login --claudeai` (not Console or an API key).",
};

function providerEnvironment(provider: Provider): NodeJS.ProcessEnv {
  // Allow installation and OS credential-store lookup, not API keys, endpoints, proxies,
  // telemetry overrides, or flags such as CLAUDECODE and CLAUDE_CODE_SIMPLE.
  const env: NodeJS.ProcessEnv = { HOME: homedir() };
  for (const key of [
    "PATH", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE",
    "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
    "DBUS_SESSION_BUS_ADDRESS", "GNOME_KEYRING_CONTROL",
    "SystemRoot", "WINDIR", "USERPROFILE", "APPDATA", "LOCALAPPDATA",
    "MISE_CONFIG_DIR", "MISE_DATA_DIR", "MISE_CACHE_DIR",
  ]) {
    const value = process.env[key];
    if (value !== undefined) env[key] = value;
  }
  const configDir = provider === "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR";
  const directory = process.env[configDir];
  if (directory) env[configDir] = resolve(directory);
  if (provider === "claude") env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
  return env;
}

async function checkCodexDotenv(env: NodeJS.ProcessEnv): Promise<void> {
  // Codex loads this even with --ignore-user-config, replacing inherited variables.
  const dotenv = join(env.CODEX_HOME ?? join(homedir(), ".codex"), ".env");
  try {
    await lstat(dotenv);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
    throw new Error("Cannot verify that the Codex home is free of .env overrides.");
  }
  throw new Error("Codex loads .env from its home even in isolated mode. Move that file aside or use a Codex home without .env and sign in there.");
}

interface CommandResult {
  code: number | null;
  termination: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
}

async function runProvider(
  provider: Provider,
  args: string[],
  cwd: string,
  env: NodeJS.ProcessEnv,
  signal: AbortSignal,
  input = "",
): Promise<CommandResult> {
  signal.throwIfAborted();
  const group = process.platform !== "win32";
  const child = spawn(provider, args, { cwd, env, shell: false, detached: group, stdio: "pipe" });
  const closed = once(child, "close");
  const abort = () => {
    if (child.pid === undefined) return;
    if (group) {
      try {
        process.kill(-child.pid, "SIGKILL");
        return;
      } catch {
        // The group may already have exited.
      }
    }
    child.kill("SIGKILL");
  };
  signal.addEventListener("abort", abort, { once: true });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (chunk: string) => { stdout += chunk; });
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => { stderr += chunk; });
  child.stdin.on("error", () => { /* A CLI can close stdin early; handle its exit status. */ });
  child.stdin.end(input);
  try {
    const [code, termination] = await closed as [number | null, NodeJS.Signals | null];
    signal.throwIfAborted();
    return { code, termination, stdout, stderr };
  } catch (error) {
    signal.throwIfAborted();
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      throw new Error(`${DISPLAY_NAME[provider]} CLI was not found on PATH.`);
    }
    throw new Error(`Could not run the ${DISPLAY_NAME[provider]} CLI.`);
  } finally {
    signal.removeEventListener("abort", abort);
  }
}

function parseObject(json: string): Record<string, unknown> | undefined {
  try {
    const value: unknown = JSON.parse(json);
    if (value !== null && typeof value === "object") return value as Record<string, unknown>;
  } catch {
    // A malformed or unexpected response is reported without exposing raw CLI output.
  }
  return undefined;
}

function commandError(provider: Provider, result: CommandResult, phase: "login check" | "request"): Error {
  const name = DISPLAY_NAME[provider];
  // CLI diagnostics can contain credential fragments, private endpoints, or the prompt.
  // Classify known failures but never pass diagnostics through to the UI.
  const diagnostic = `${result.stderr}\n${result.stdout}`;
  if (/not logged in|not authenticated|invalid (?:api key|oauth token)|unauthori[sz]ed|authentication (?:failed|required)|\b401\b.*unauthor/i.test(diagnostic)) {
    return new Error(LOGIN_HELP[provider]);
  }
  if (/rate limit|usage limit|quota exceeded|\b429\b/i.test(diagnostic)) {
    return new Error(`${name} reported a usage or rate limit. Check your subscription limits.`);
  }
  if (/unexpected argument|unknown option|unrecognized option|unknown feature/i.test(diagnostic)) {
    return new Error(`${name} CLI does not support the required isolation options. Update the CLI.`);
  }
  if (/connection refused|network error|failed to connect|dns error|timed out/i.test(diagnostic)) {
    return new Error(`${name} could not reach its service. Check your network connection.`);
  }
  const status = result.termination ?? (result.code ? `exit ${result.code}` : "error result");
  return new Error(`${name} ${phase} failed (${status}). Check the CLI and your login.`);
}

async function requireSubscription(
  provider: Provider, cwd: string, env: NodeJS.ProcessEnv, signal: AbortSignal,
): Promise<void> {
  if (provider === "codex") {
    const status = await runProvider(provider, ["login", "status", ...CODEX_CONFIG], cwd, env, signal);
    if (status.code !== 0) throw commandError(provider, status, "login check");
    if (!/^Logged in using ChatGPT\r?$/m.test(`${status.stdout}\n${status.stderr}`)) {
      throw new Error(LOGIN_HELP.codex);
    }
    return;
  }
  const status = await runProvider(provider, [...CLAUDE_SETTINGS, "auth", "status", "--json"], cwd, env, signal);
  const login = parseObject(status.stdout);
  if (login?.loggedIn === false) throw new Error(LOGIN_HELP.claude);
  if (status.code !== 0) throw commandError(provider, status, "login check");
  if (login?.loggedIn !== true || login.authMethod !== "claude.ai" || login.apiProvider !== "firstParty"
    || typeof login.subscriptionType !== "string" || !CLAUDE_PLANS.includes(login.subscriptionType)) {
    throw new Error(`Claude Code did not confirm a subscription. ${LOGIN_HELP.claude}`);
  }
}

function codexResponse(result: CommandResult): string | undefined {
  let completed = false;
  let message: string | undefined;
  for (const line of result.stdout.split("\n")) {
    if (!line.trim()) continue;
    const event = parseObject(line);
    if (!event || event.type === "turn.failed") return undefined;
    if (event.type === "turn.completed") completed = true;
    if (event.type === "item.completed") {
      const item = event.item as Record<string, unknown> | undefined;
      if (item?.type === "agent_message" && typeof item.text === "string") message = item.text;
    }
  }
  return completed ? message : undefined;
}

export async function askProvider(provider: Provider, prompt: string, signal: AbortSignal): Promise<string> {
  signal.throwIfAborted();
  const env = providerEnvironment(provider);
  if (provider === "codex") await checkCodexDotenv(env);
  signal.throwIfAborted();
  const cwd = await mkdtemp(join(tmpdir(), "spider-provider-"));
  try {
    await requireSubscription(provider, cwd, env, signal);
    const result = await runProvider(provider, provider === "codex" ? CODEX_EXEC : CLAUDE_PRINT, cwd, env, signal, prompt);
    if (result.code !== 0) throw commandError(provider, result, "request");
    if (provider === "codex") {
      const answer = codexResponse(result);
      if (answer?.trim()) return answer;
    } else {
      const response = parseObject(result.stdout);
      if (response?.is_error === true) throw commandError(provider, result, "request");
      if (response?.type === "result" && response.subtype === "success" && response.is_error === false
        && typeof response.result === "string" && response.result.trim()) return response.result;
    }
    throw new Error(`${DISPLAY_NAME[provider]} did not return a completed text response.`);
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
}
