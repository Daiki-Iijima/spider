import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import { lstat, mkdtemp, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";

export type Provider = "codex" | "claude" | "omp";

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

// ACP does not discover MCP servers; the client supplies an empty list in session/new.
const OMP_ARGS = [
  "--mode", "acp", "--no-session", "--no-tools", "--no-extensions", "--no-skills",
  "--no-rules", "--no-context-files", "--no-lsp", "--no-pty", "--no-title", "--no-prewalk", "--offline",
  "--system-prompt", "You are a conversational assistant. Answer the last user message in the supplied Spider conversation.",
];
const OMP_CONFIG = {
  advisor: { enabled: false },
  memories: { enabled: false },
  hindsight: { autoRecall: false, autoRetain: false },
  telemetry: { otlpExportEnabled: false },
};

const DISPLAY_NAME: Record<Provider, string> = { codex: "Codex", claude: "Claude Code", omp: "omp" };
const LOGIN_HELP: Record<Provider, string> = {
  codex: "`codex login` で ChatGPT アカウントにログインしてください。API キーは使いません。",
  claude: "`claude auth login --claudeai` で Claude のサブスクリプションにログインしてください。Console や API キーは使いません。",
  omp: "`omp login` で使う接続先にログインし、omp のモデル設定を確認してください。",
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
  const configKeys = provider === "omp" ? ["OMP_PROFILE", "PI_PROFILE", "PI_CONFIG_DIR", "PI_CODING_AGENT_DIR"]
    : provider === "codex" ? ["CODEX_HOME"] : ["CLAUDE_CONFIG_DIR"];
  for (const key of configKeys) {
    const value = process.env[key];
    if (value) env[key] = key.endsWith("_PROFILE") ? value : resolve(value);
  }
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
    throw new Error("Codex の設定ディレクトリに .env がないことを確認できませんでした。");
  }
  throw new Error("Codex の設定ディレクトリに .env があります。退避するか、.env のない設定ディレクトリでログインしてください。");
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
  input: string | ((child: ChildProcessWithoutNullStreams) => Promise<string>) = "",
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
  let output = "";
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => { stderr += chunk; });
  child.stdin.on("error", () => { /* A CLI can close stdin early; handle its exit status. */ });
  try {
    let response: Promise<string> | string;
    if (typeof input === "string") {
      child.stdout.setEncoding("utf8").on("data", (chunk: string) => { output += chunk; });
      child.stdin.end(input);
      response = "";
    } else {
      response = input(child);
    }
    const [[code, termination], answer] = await Promise.all([
      closed as Promise<[number | null, NodeJS.Signals | null]>, response,
    ]);
    signal.throwIfAborted();
    return { code, termination, stdout: typeof input === "string" ? output : answer, stderr };
  } catch (error) {
    abort();
    await closed.catch(() => {});
    signal.throwIfAborted();
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      throw new Error(`${DISPLAY_NAME[provider]} CLI が PATH に見つかりません。`);
    }
    if (error instanceof OmpProtocolError) throw error;
    throw new Error(`${DISPLAY_NAME[provider]} CLI を起動できませんでした。`);
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

class OmpProtocolError extends Error {}

async function exchangeOmp(child: ChildProcessWithoutNullStreams, cwd: string, prompt: string): Promise<string> {
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const request = (id: number, method: string, params: object) => {
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  };
  let sessionId: string | undefined;
  const chunks: string[] = [];
  try {
    request(1, "initialize", { protocolVersion: 1, clientCapabilities: {} });
    for await (const line of lines) {
      const event = parseObject(line);
      if (!event) throw new OmpProtocolError("omp から無効な ACP メッセージを受信しました。");
      if (event.method && event.id !== undefined) {
        throw new OmpProtocolError("omp がチャット以外の操作を要求したため、送信を中止しました。");
      }
      const result = event.result as Record<string, unknown> | undefined;
      if (event.id === 1) {
        if (result?.protocolVersion !== 1) throw new OmpProtocolError("omp と ACP で接続できません。omp を更新してください。");
        request(2, "session/new", { cwd, mcpServers: [] });
      } else if (event.id === 2) {
        if (typeof result?.sessionId !== "string") {
          throw new OmpProtocolError(`omp で会話を開始できませんでした。${LOGIN_HELP.omp}`);
        }
        sessionId = result.sessionId;
        request(3, "session/prompt", { sessionId, prompt: [{ type: "text", text: prompt }] });
      } else if (event.method === "session/update") {
        const params = event.params as {
          sessionId?: string;
          update?: { sessionUpdate?: string; content?: { type?: string; text?: string } };
        } | undefined;
        if (!sessionId || params?.sessionId !== sessionId) continue;
        const update = params.update;
        if (update?.sessionUpdate === "agent_message_chunk" && update.content?.type === "text"
          && typeof update.content.text === "string") chunks.push(update.content.text);
      } else if (event.id === 3) {
        const answer = chunks.join("");
        if (result?.stopReason !== "end_turn" || !answer.trim()) {
          throw new OmpProtocolError(`omp の応答が完了しませんでした。${LOGIN_HELP.omp}`);
        }
        return answer;
      }
    }
    return "";
  } finally {
    lines.close();
    child.stdin.end();
  }
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
    return new Error(`${name} の使用上限に達しました。契約プランの利用状況を確認してください。`);
  }
  if (/unexpected argument|unknown option|unrecognized option|unknown feature/i.test(diagnostic)) {
    return new Error(`${name} CLI に必要なオプションがありません。CLI を更新してください。`);
  }
  if (/connection refused|network error|failed to connect|dns error|timed out/i.test(diagnostic)) {
    return new Error(`${name} のサービスに接続できませんでした。ネットワークを確認してください。`);
  }
  const status = result.termination ?? (result.code ? `終了コード ${result.code}` : "エラー応答");
  return new Error(`${name} の${phase === "login check" ? "ログイン確認" : "リクエスト"}に失敗しました (${status})。CLI とログイン状態を確認してください。`);
}

async function requireSubscription(
  provider: Exclude<Provider, "omp">, cwd: string, env: NodeJS.ProcessEnv, signal: AbortSignal,
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
    throw new Error(`Claude Code のサブスクリプションを確認できませんでした。${LOGIN_HELP.claude}`);
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
    if (provider === "omp") {
      const config = join(cwd, "spider.json");
      await writeFile(config, JSON.stringify(OMP_CONFIG), { mode: 0o600 });
      const args = [...OMP_ARGS, "--config", config, "--session-dir", join(cwd, "sessions")];
      const model = process.env.SPIDER_OMP_MODEL?.trim();
      if (model) args.push(`--model=${model}`);
      const result = await runProvider(provider, args, cwd, env, signal, child => exchangeOmp(child, cwd, prompt));
      if (result.code !== 0) throw commandError(provider, result, "request");
      if (result.stdout.trim()) return result.stdout;
      throw new Error(`omp から回答を受け取れませんでした。${LOGIN_HELP.omp}`);
    }
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
    throw new Error(`${DISPLAY_NAME[provider]} から回答を受け取れませんでした。`);
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
}
