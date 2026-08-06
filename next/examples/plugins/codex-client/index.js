// Mobile-native client for the stable Codex app-server protocol surface.
//
// The plugin intentionally owns every Codex-specific concern. OpenVS Mobile
// core only sees a normal typed UI tree, ui.event callbacks, and plugin
// notifications; no Codex methods or TUI parsing leak into the host runtime.

import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";

import { createPlugin, ui } from "@openvsmobile/sdk";

import { CodexAppServerClient, CodexRpcError } from "./app_server.js";

const PANEL_ID = "chat";
const PLUGIN_VERSION = "0.1.0";
const DEFAULT_ENDPOINT = "ws://127.0.0.1:4500";
const MAX_MESSAGES = 60;
const MAX_VISIBLE_MESSAGES = 30;
const MAX_COMMAND_OUTPUT_CHARS = 4_000;
const MAX_CREDENTIAL_BYTES = 8_192;
const RENDER_THROTTLE_MS = 80;
const RECONNECT_MAX_MS = 30_000;
const OVERLOAD_RETRIES = 3;

function env(name, fallback = "") {
  const value = process.env[`OPENVSMOBILE_PLUGIN_${name}`];
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

const config = {
  endpoint: env("CODEX_CONNECT", DEFAULT_ENDPOINT),
  credentialFile: env("CODEX_CREDENTIAL_FILE"),
  cwd: env("CODEX_CWD"),
  model: env("CODEX_MODEL"),
  approvalPolicy: env("CODEX_APPROVAL_POLICY", "on-request"),
  sandbox: env("CODEX_SANDBOX", "workspace-write"),
};

const state = {
  ctx: null,
  client: null,
  connection: "disconnected",
  error: "",
  serverUserAgent: "",
  cwd: "",
  workspaceLabel: "",
  draft: "",
  activeThreadId: null,
  activeThreadPreview: "",
  activeTurnId: null,
  turnStatus: "",
  messages: [],
  recentThreads: [],
  showHistory: false,
  showDetails: false,
  pendingApprovals: new Map(),
  nextApprovalKey: 1,
  lastNotificationId: null,
  lastNotifiedTurnId: null,
  renderTimer: null,
  reconnectTimer: null,
  reconnectDelayMs: 1_000,
  everConnected: false,
  resetThreadAfterTurn: false,
};

function isLoopback(hostname) {
  return (
    hostname === "localhost" ||
    hostname === "127.0.0.1" ||
    hostname === "::1" ||
    hostname === "[::1]"
  );
}

function validatedEndpoint() {
  let endpoint;
  try {
    endpoint = new URL(config.endpoint);
  } catch {
    throw new Error("CODEX_CONNECT is not a valid URL");
  }
  if (endpoint.protocol !== "ws:" && endpoint.protocol !== "wss:") {
    throw new Error("CODEX_CONNECT must use ws:// or wss://");
  }
  if (endpoint.username || endpoint.password) {
    throw new Error(
      "put the bearer credential in CODEX_CREDENTIAL_FILE, not the URL",
    );
  }
  if (endpoint.protocol === "ws:" && !isLoopback(endpoint.hostname)) {
    throw new Error(
      "plain ws:// is only allowed for loopback or an SSH-forwarded listener",
    );
  }
  if (!isLoopback(endpoint.hostname) && !config.credentialFile) {
    throw new Error("remote Codex endpoints require CODEX_CREDENTIAL_FILE");
  }
  return endpoint.toString();
}

function displayEndpoint() {
  try {
    const endpoint = new URL(config.endpoint);
    endpoint.username = "";
    endpoint.password = "";
    endpoint.search = "";
    endpoint.hash = "";
    return endpoint.toString();
  } catch {
    return "invalid endpoint";
  }
}

function validateThreadDefaults() {
  if (
    !new Set(["untrusted", "on-request", "never"]).has(config.approvalPolicy)
  ) {
    throw new Error(
      "CODEX_APPROVAL_POLICY must be untrusted, on-request, or never",
    );
  }
  if (
    !new Set(["read-only", "workspace-write", "danger-full-access"]).has(
      config.sandbox,
    )
  ) {
    throw new Error(
      "CODEX_SANDBOX must be read-only, workspace-write, or danger-full-access",
    );
  }
}

async function loadBearerCredential() {
  if (!config.credentialFile) return "";
  const bytes = await readFile(config.credentialFile);
  if (bytes.length > MAX_CREDENTIAL_BYTES) {
    throw new Error("Codex credential file is unexpectedly large");
  }
  const credential = bytes.toString("utf8").trim();
  if (!credential) throw new Error("Codex credential file is empty");
  return credential;
}

function errorMessage(err) {
  if (err instanceof Error && err.message) return err.message;
  return String(err);
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function scheduleRender({ immediate = false } = {}) {
  if (state.ctx === null) return;
  if (immediate) {
    if (state.renderTimer !== null) clearTimeout(state.renderTimer);
    state.renderTimer = null;
    render();
    return;
  }
  if (state.renderTimer !== null) return;
  state.renderTimer = setTimeout(() => {
    state.renderTimer = null;
    render();
  }, RENDER_THROTTLE_MS);
}

function activeClient() {
  if (state.connection !== "connected" || state.client === null) {
    throw new Error("Codex app-server is not connected");
  }
  return state.client;
}

async function rpc(method, params = {}) {
  let attempt = 0;
  while (true) {
    try {
      return await activeClient().request(method, params);
    } catch (err) {
      attempt += 1;
      if (
        !(err instanceof CodexRpcError) ||
        err.code !== -32001 ||
        attempt >= OVERLOAD_RETRIES
      ) {
        throw err;
      }
      const delay = 200 * 2 ** (attempt - 1) + Math.floor(Math.random() * 100);
      await wait(delay);
    }
  }
}

async function refreshWorkspace(ctx, workspace = undefined) {
  if (config.cwd) {
    state.cwd = config.cwd;
    state.workspaceLabel = "configured cwd";
    return;
  }
  try {
    const current =
      workspace === undefined ? await ctx.currentWorkspace() : workspace;
    if (current?.root) {
      state.cwd = current.root;
      state.workspaceLabel = current.label || current.root;
      return;
    }
  } catch (err) {
    state.error = `Could not read the active workspace: ${errorMessage(err)}`;
  }
  state.cwd = process.cwd();
  state.workspaceLabel = "plugin process";
}

function clearReconnectTimer() {
  if (state.reconnectTimer !== null) {
    clearTimeout(state.reconnectTimer);
    state.reconnectTimer = null;
  }
}

function scheduleReconnect() {
  if (state.reconnectTimer !== null || !state.everConnected) return;
  const jitter = Math.floor(
    Math.random() * Math.max(100, state.reconnectDelayMs / 4),
  );
  const delay = state.reconnectDelayMs + jitter;
  state.reconnectDelayMs = Math.min(
    state.reconnectDelayMs * 2,
    RECONNECT_MAX_MS,
  );
  state.reconnectTimer = setTimeout(() => {
    state.reconnectTimer = null;
    void connect();
  }, delay);
}

async function connect() {
  clearReconnectTimer();
  const previous = state.client;
  state.client = null;
  previous?.close();
  state.connection = "connecting";
  state.error = "";
  scheduleRender({ immediate: true });

  let client;
  try {
    validateThreadDefaults();
    const endpoint = validatedEndpoint();
    const bearerToken = await loadBearerCredential();
    client = new CodexAppServerClient({ endpoint, bearerToken });
    state.client = client;
    client.on("notification", (message) => {
      if (state.client === client) void handleNotification(message);
    });
    client.on("request", (message) => {
      if (state.client === client) void handleServerRequest(message);
    });
    client.on("error", (err) => {
      if (state.client !== client) return;
      state.error = errorMessage(err);
      scheduleRender({ immediate: true });
    });
    client.on("close", ({ intentional }) => {
      if (state.client !== client) return;
      state.client = null;
      state.connection = "disconnected";
      if (!intentional && !state.error)
        state.error = "Codex app-server disconnected";
      state.pendingApprovals.clear();
      scheduleRender({ immediate: true });
      if (!intentional) scheduleReconnect();
    });

    await client.connect();
    const initialized = await client.request("initialize", {
      clientInfo: {
        name: "openvsmobile",
        title: "OpenVS Mobile",
        version: PLUGIN_VERSION,
      },
    });
    client.notify("initialized", {});
    if (state.client !== client) return;
    state.connection = "connected";
    state.error = "";
    state.serverUserAgent =
      typeof initialized?.userAgent === "string"
        ? initialized.userAgent
        : "Codex app-server";
    state.everConnected = true;
    state.reconnectDelayMs = 1_000;

    if (state.activeThreadId) {
      await resumeThread(state.activeThreadId, { fromReconnect: true });
    } else {
      await refreshRecentThreads();
    }
    scheduleRender({ immediate: true });
  } catch (err) {
    if (client !== undefined && state.client === client) {
      state.client = null;
      client.close();
    }
    state.connection = "disconnected";
    state.error = errorMessage(err);
    scheduleRender({ immediate: true });
    scheduleReconnect();
  }
}

async function refreshRecentThreads() {
  const params = {
    limit: 8,
    sortKey: "recency_at",
    sortDirection: "desc",
  };
  if (state.cwd) params.cwd = state.cwd;
  const result = await rpc("thread/list", params);
  state.recentThreads = Array.isArray(result?.data) ? result.data : [];
}

function threadLabel(thread) {
  const name = typeof thread?.name === "string" ? thread.name.trim() : "";
  const preview =
    typeof thread?.preview === "string" ? thread.preview.trim() : "";
  return name || preview || "Untitled Codex thread";
}

async function ensureThread() {
  if (state.activeThreadId) return state.activeThreadId;
  const params = {
    cwd: state.cwd || undefined,
    approvalPolicy: config.approvalPolicy,
    sandbox: config.sandbox,
  };
  if (config.model) params.model = config.model;
  const result = await rpc("thread/start", params);
  const thread = result?.thread;
  if (!thread || typeof thread.id !== "string") {
    throw new Error("thread/start response did not include a thread id");
  }
  state.activeThreadId = thread.id;
  state.activeThreadPreview = threadLabel(thread);
  state.messages = [];
  await refreshRecentThreads().catch(() => {});
  return thread.id;
}

function textFromUserInput(content) {
  if (!Array.isArray(content)) return "";
  return content
    .filter((part) => part?.type === "text" && typeof part.text === "string")
    .map((part) => part.text)
    .join("\n");
}

function truncate(text, max = MAX_COMMAND_OUTPUT_CHARS) {
  const value = String(text ?? "");
  return value.length <= max ? value : `${value.slice(0, max)}\n…`;
}

function messageFromItem(item) {
  if (!item || typeof item !== "object" || typeof item.id !== "string")
    return null;
  switch (item.type) {
    case "userMessage":
      return {
        id: typeof item.clientId === "string" ? item.clientId : item.id,
        role: "user",
        text: textFromUserInput(item.content),
        kind: "text",
      };
    case "agentMessage":
      return {
        id: item.id,
        role: "assistant",
        text: item.text || "",
        kind: "markdown",
      };
    case "plan":
      return {
        id: item.id,
        role: "assistant",
        text: item.text || "",
        kind: "plan",
      };
    case "commandExecution": {
      const output =
        typeof item.aggregatedOutput === "string" ? item.aggregatedOutput : "";
      const suffix = output ? `\n${truncate(output)}` : "";
      return {
        id: item.id,
        role: "tool",
        text: `$ ${item.command || "command"}${suffix}`,
        kind: "command",
      };
    }
    case "fileChange":
      return {
        id: item.id,
        role: "tool",
        text: `File changes: ${Array.isArray(item.changes) ? item.changes.length : 0}`,
        kind: "status",
      };
    case "mcpToolCall":
      return {
        id: item.id,
        role: "tool",
        text: `${item.server || "MCP"} · ${item.tool || "tool"} · ${item.status || "started"}`,
        kind: "status",
      };
    default:
      return null;
  }
}

function upsertMessage(message, { append = false } = {}) {
  if (!message || !message.text) return;
  const existing = state.messages.find(
    (candidate) => candidate.id === message.id,
  );
  if (existing) {
    existing.role = message.role;
    existing.kind = message.kind;
    existing.text = append ? `${existing.text}${message.text}` : message.text;
  } else {
    state.messages.push({ ...message });
  }
  if (state.messages.length > MAX_MESSAGES) {
    state.messages.splice(0, state.messages.length - MAX_MESSAGES);
  }
}

function hydrateThread(thread) {
  state.activeThreadPreview = threadLabel(thread);
  const messages = [];
  const turns = Array.isArray(thread?.turns) ? thread.turns : [];
  for (const turn of turns) {
    if (!Array.isArray(turn?.items)) continue;
    for (const item of turn.items) {
      const message = messageFromItem(item);
      if (message?.text) messages.push(message);
    }
  }
  state.messages = messages.slice(-MAX_MESSAGES);
  const running = [...turns]
    .reverse()
    .find((turn) => turn?.status === "inProgress");
  state.activeTurnId = typeof running?.id === "string" ? running.id : null;
  state.turnStatus = state.activeTurnId ? "Codex is working" : "";
}

async function resumeThread(threadId, { fromReconnect = false } = {}) {
  const result = await rpc("thread/resume", {
    threadId,
    cwd: state.cwd || undefined,
  });
  const thread = result?.thread;
  if (!thread || typeof thread.id !== "string") {
    throw new Error("thread/resume response did not include a thread");
  }
  state.activeThreadId = thread.id;
  hydrateThread(thread);
  if (!fromReconnect) state.showHistory = false;
  scheduleRender({ immediate: true });
}

function makeTextInput(text) {
  return [{ type: "text", text, text_elements: [] }];
}

async function submitText(raw) {
  const text = String(raw ?? "").trim();
  if (!text) return;
  try {
    const threadId = await ensureThread();
    const clientUserMessageId = randomUUID();
    upsertMessage({
      id: clientUserMessageId,
      role: "user",
      text,
      kind: "text",
    });
    state.draft = "";
    state.error = "";
    scheduleRender({ immediate: true });

    if (state.activeTurnId) {
      await rpc("turn/steer", {
        threadId,
        expectedTurnId: state.activeTurnId,
        clientUserMessageId,
        input: makeTextInput(text),
      });
      state.turnStatus = "Message added to the active turn";
      scheduleRender({ immediate: true });
      return;
    }

    const result = await rpc("turn/start", {
      threadId,
      clientUserMessageId,
      input: makeTextInput(text),
    });
    if (typeof result?.turn?.id !== "string") {
      throw new Error("turn/start response did not include a turn id");
    }
    state.activeTurnId = result.turn.id;
    state.turnStatus = "Codex is working";
    scheduleRender({ immediate: true });
  } catch (err) {
    state.error = errorMessage(err);
    state.turnStatus = "";
    scheduleRender({ immediate: true });
  }
}

async function interruptTurn() {
  if (!state.activeThreadId || !state.activeTurnId) return;
  try {
    state.turnStatus = "Stopping Codex";
    scheduleRender({ immediate: true });
    await rpc("turn/interrupt", {
      threadId: state.activeThreadId,
      turnId: state.activeTurnId,
    });
  } catch (err) {
    state.error = errorMessage(err);
    scheduleRender({ immediate: true });
  }
}

function lastAssistantText() {
  for (let i = state.messages.length - 1; i >= 0; i -= 1) {
    const message = state.messages[i];
    if (message.role === "assistant" && message.text.trim())
      return message.text.trim();
  }
  return "";
}

async function notifyTurnCompleted(turnId) {
  if (!state.ctx || state.lastNotifiedTurnId === turnId) return;
  const body = lastAssistantText();
  if (!body) return;
  const input = {
    level: "info",
    title: "Codex replied",
    body,
    spoken: { title: "Codex replied", body },
    reply: {
      event: "codex.reply",
      context: { threadId: state.activeThreadId },
      placeholder: "Reply to Codex",
    },
    groupKey: `codex:${state.activeThreadId ?? "thread"}`,
  };
  if (state.lastNotificationId) input.supersedes = state.lastNotificationId;
  try {
    const result = await state.ctx.showNotification(input);
    state.lastNotificationId = result.id;
    state.lastNotifiedTurnId = turnId;
  } catch (err) {
    state.ctx.log("warn", `Codex notification failed: ${errorMessage(err)}`);
  }
}

function approvalBody(method, params) {
  if (method === "item/commandExecution/requestApproval") {
    const lines = [];
    if (params?.reason) lines.push(String(params.reason));
    if (params?.command) lines.push(`Command: ${params.command}`);
    if (params?.cwd) lines.push(`Directory: ${params.cwd}`);
    return lines.join("\n") || "Codex wants to run a command.";
  }
  const lines = [];
  if (params?.reason) lines.push(String(params.reason));
  if (params?.grantRoot) lines.push(`Write access: ${params.grantRoot}`);
  return lines.join("\n") || "Codex wants to change files.";
}

async function handleServerRequest(message) {
  const client = state.client;
  if (
    client === null ||
    (typeof message.id !== "number" && typeof message.id !== "string")
  ) {
    return;
  }
  const isCommand = message.method === "item/commandExecution/requestApproval";
  const isFile = message.method === "item/fileChange/requestApproval";
  if (!isCommand && !isFile) {
    client.respondError(
      message.id,
      -32601,
      `OpenVS Mobile does not handle ${message.method}`,
    );
    state.error = `Codex requested unsupported client input: ${message.method}`;
    scheduleRender({ immediate: true });
    return;
  }

  const key = String(state.nextApprovalKey++);
  state.pendingApprovals.set(key, {
    requestId: message.id,
    method: message.method,
    params: message.params ?? {},
  });
  scheduleRender({ immediate: true });
  try {
    await state.ctx.showAlert(PANEL_ID, {
      id: `codex-approval-${key}`,
      title: isCommand ? "Allow this command?" : "Allow these file changes?",
      body: approvalBody(message.method, message.params),
      actions: [
        {
          label: "Deny",
          eventId: `approval:${key}:decline`,
          variant: "danger",
        },
        { label: "Allow once", eventId: `approval:${key}:accept` },
        {
          label: "Allow for session",
          eventId: `approval:${key}:acceptForSession`,
        },
      ],
      dismissible: false,
    });
  } catch (err) {
    state.pendingApprovals.delete(key);
    if (state.client === client && client.connected) {
      client.respond(message.id, { decision: "decline" });
    }
    state.error = `Could not show approval: ${errorMessage(err)}`;
    scheduleRender({ immediate: true });
  }
}

async function answerApproval(key, decision) {
  const pending = state.pendingApprovals.get(key);
  if (!pending) return;
  state.pendingApprovals.delete(key);
  try {
    activeClient().respond(pending.requestId, { decision });
  } catch (err) {
    state.error = errorMessage(err);
  }
  scheduleRender({ immediate: true });
}

async function handleNotification(message) {
  const params = message.params ?? {};
  switch (message.method) {
    case "turn/started":
      if (
        params.threadId === state.activeThreadId &&
        typeof params.turn?.id === "string"
      ) {
        state.activeTurnId = params.turn.id;
        state.turnStatus = "Codex is working";
        scheduleRender({ immediate: true });
      }
      return;
    case "item/agentMessage/delta":
      if (
        params.threadId === state.activeThreadId &&
        typeof params.itemId === "string"
      ) {
        upsertMessage(
          {
            id: params.itemId,
            role: "assistant",
            text: typeof params.delta === "string" ? params.delta : "",
            kind: "markdown",
          },
          { append: true },
        );
        state.turnStatus = "Codex is replying";
        scheduleRender();
      }
      return;
    case "item/started":
    case "item/completed":
      if (params.threadId === state.activeThreadId) {
        const itemMessage = messageFromItem(params.item);
        if (itemMessage) upsertMessage(itemMessage);
        scheduleRender(
          message.method === "item/completed" ? { immediate: true } : {},
        );
      }
      return;
    case "turn/completed":
      if (params.threadId !== state.activeThreadId) return;
      if (Array.isArray(params.turn?.items)) {
        for (const item of params.turn.items) {
          const itemMessage = messageFromItem(item);
          if (itemMessage) upsertMessage(itemMessage);
        }
      }
      state.activeTurnId = null;
      state.turnStatus =
        params.turn?.status === "failed" ? "Codex turn failed" : "";
      if (params.turn?.error?.message) state.error = params.turn.error.message;
      scheduleRender({ immediate: true });
      if (typeof params.turn?.id === "string")
        await notifyTurnCompleted(params.turn.id);
      if (state.resetThreadAfterTurn) {
        state.resetThreadAfterTurn = false;
        state.activeThreadId = null;
        state.activeThreadPreview = "";
      }
      await refreshRecentThreads().catch(() => {});
      scheduleRender({ immediate: true });
      return;
    case "serverRequest/resolved":
      for (const [key, pending] of state.pendingApprovals) {
        if (pending.requestId === params.requestId)
          state.pendingApprovals.delete(key);
      }
      scheduleRender({ immediate: true });
      return;
    case "error":
      state.error =
        params.error?.message || params.message || "Codex app-server error";
      scheduleRender({ immediate: true });
      return;
    case "warning":
    case "configWarning":
    case "deprecationNotice":
      state.error = params.message || params.summary || "Codex warning";
      scheduleRender({ immediate: true });
      return;
    default:
      return;
  }
}

function statusTitle() {
  if (state.connection === "connected")
    return state.activeTurnId ? "Codex is working" : "Connected";
  if (state.connection === "connecting") return "Connecting";
  return "Disconnected";
}

function statusBody() {
  if (state.error) return state.error;
  if (state.turnStatus) return state.turnStatus;
  if (state.connection === "connected") {
    return state.activeThreadId
      ? `Thread ${state.activeThreadPreview}`
      : "Ready for a new thread";
  }
  if (state.connection === "connecting") return `Opening ${displayEndpoint()}`;
  return "Start codex app-server or check the connection settings.";
}

function statusAccent() {
  if (state.error) return "warning";
  if (state.connection === "connected") return "success";
  if (state.connection === "connecting") return "info";
  return "warning";
}

function actionTile({
  id,
  title,
  subtitle,
  icon,
  accent = "brand",
  eventId = "tap",
  danger = false,
}) {
  return ui.withMetadata(
    ui.listTile({
      id,
      title,
      subtitle,
      onTapEvent: eventId,
      leading: ui.icon({ id: `${id}-icon`, name: icon, accent }),
    }),
    {
      accessibilityLabel: title,
      accessibilityHint: subtitle,
      spokenValue: subtitle ? `${title}. ${subtitle}` : title,
      focusRole: danger ? "danger" : "action",
    },
  );
}

function messageNode(message) {
  if (message.role === "assistant") {
    return ui.section({
      id: `message-${message.id}`,
      title: message.kind === "plan" ? "Codex plan" : "Codex",
      children: [
        ui.markdown({
          id: `message-${message.id}-body`,
          markdown: message.text,
        }),
      ],
    });
  }
  if (message.role === "user") {
    return ui.section({
      id: `message-${message.id}`,
      title: "You",
      variant: "inset",
      children: [
        ui.text({ id: `message-${message.id}-body`, text: message.text }),
      ],
    });
  }
  if (message.kind === "command") {
    return ui.section({
      id: `message-${message.id}`,
      title: "Command",
      collapsible: true,
      children: [
        ui.codeBlock({
          id: `message-${message.id}-body`,
          code: message.text,
          language: "shell",
        }),
      ],
    });
  }
  return ui.listTile({
    id: `message-${message.id}`,
    title: "Codex activity",
    subtitle: message.text,
    leading: ui.icon({
      id: `message-${message.id}-icon`,
      name: "activity",
      accent: "muted",
    }),
  });
}

function recentThreadNode(thread) {
  const id = String(thread.id);
  const updated = Number.isFinite(thread.updatedAt)
    ? new Date(thread.updatedAt * 1000).toLocaleString()
    : "";
  return ui.listTile({
    id: `codex-thread-${id}`,
    title: threadLabel(thread),
    subtitle: updated,
    onTapEvent: `resume:${id}`,
    leading: ui.icon({
      id: `codex-thread-${id}-icon`,
      name: "message-square",
      accent: "info",
    }),
  });
}

function buildTree() {
  const visibleMessages = state.messages.slice(-MAX_VISIBLE_MESSAGES);
  const children = [
    ui.withMetadata(
      ui.banner({
        id: "codex-status",
        title: statusTitle(),
        body: statusBody(),
        accent: statusAccent(),
        action:
          state.connection === "connected"
            ? undefined
            : { label: "Retry", eventId: "retry" },
      }),
      {
        accessibilityLabel: "Codex connection status",
        spokenValue: statusBody(),
        focusRole: "status",
        focusOrder: 0,
      },
    ),
  ];

  if (state.activeTurnId) {
    children.push(
      ui.progress({
        id: "codex-active-turn",
        label: state.turnStatus || "Codex is working",
        variant: "linear",
        accent: "info",
      }),
    );
  }
  if (state.pendingApprovals.size > 0) {
    children.push(
      ui.banner({
        id: "codex-pending-approval",
        title: "Approval needed",
        body: `${state.pendingApprovals.size} Codex request(s) are waiting for a decision.`,
        accent: "warning",
      }),
    );
  }

  children.push(
    ui.section({
      id: "codex-conversation",
      title: state.activeThreadPreview || "Conversation",
      children:
        visibleMessages.length > 0
          ? visibleMessages.map(messageNode)
          : [
              ui.text({
                id: "codex-empty-conversation",
                text: "Send a message to start a Codex thread, or resume one from Recent threads.",
                style: "caption",
              }),
            ],
    }),
    ui.section({
      id: "codex-compose",
      title: "Message",
      variant: "inset",
      children: [
        ui.withMetadata(
          ui.textField({
            id: "codex-input",
            label: "Ask Codex",
            value: state.draft,
            placeholder: "Describe what you want Codex to do",
          }),
          {
            accessibilityLabel: "Ask Codex",
            accessibilityHint: "Type a coding request.",
            focusRole: "input",
          },
        ),
      ],
    }),
    ui.section({
      id: "codex-actions",
      title: "Actions",
      variant: "inset",
      children: [
        actionTile({
          id: "codex-send",
          title: state.activeTurnId ? "Steer active turn" : "Send to Codex",
          subtitle: state.draft.trim()
            ? "Sends the text above"
            : "Type a request first",
          icon: "send",
        }),
        actionTile({
          id: "codex-stop",
          title: "Stop current turn",
          subtitle: state.activeTurnId
            ? "Interrupts the running Codex turn"
            : "No running turn",
          icon: "square-stop",
          accent: "danger",
          danger: true,
        }),
        actionTile({
          id: "codex-new-thread",
          title: "New thread",
          subtitle: "Starts a clean conversation on the next message",
          icon: "plus-circle",
        }),
        actionTile({
          id: "codex-toggle-history",
          title: state.showHistory
            ? "Hide recent threads"
            : "Show recent threads",
          subtitle: `${state.recentThreads.length} thread(s) for this workspace`,
          icon: "clock",
        }),
      ],
    }),
  );

  if (state.showHistory) {
    children.push(
      ui.section({
        id: "codex-recent-threads",
        title: "Recent threads",
        variant: "inset",
        children:
          state.recentThreads.length > 0
            ? state.recentThreads.map(recentThreadNode)
            : [
                ui.text({
                  id: "codex-no-recent-threads",
                  text: "No stored Codex threads match this workspace.",
                  style: "caption",
                }),
              ],
      }),
    );
  }

  children.push(
    actionTile({
      id: "codex-toggle-details",
      title: state.showDetails
        ? "Hide connection details"
        : "Show connection details",
      subtitle: "Endpoint, workspace, and Codex version",
      icon: "info",
      accent: "muted",
    }),
  );
  if (state.showDetails) {
    children.push(
      ui.section({
        id: "codex-details",
        title: "Connection",
        children: [
          ui.text({
            id: "codex-endpoint",
            text: displayEndpoint(),
            style: "mono",
          }),
          ui.text({
            id: "codex-cwd",
            text: `cwd ${state.cwd || "(unset)"}`,
            style: "mono",
          }),
          ui.text({
            id: "codex-workspace",
            text: `workspace ${state.workspaceLabel || "(none)"}`,
            style: "caption",
          }),
          ui.text({
            id: "codex-server-version",
            text: state.serverUserAgent || "Codex version unavailable",
            style: "caption",
          }),
          ui.text({
            id: "codex-security",
            text: config.credentialFile
              ? "Bearer authentication configured through a credential file."
              : "Loopback connection without WebSocket authentication.",
            style: "caption",
          }),
        ],
      }),
    );
  }

  return ui.column({ id: "codex-root", gap: "md", children });
}

function render() {
  state.ctx?.renderPanel(PANEL_ID, buildTree());
}

const plugin = createPlugin({
  async onActivate(ctx) {
    state.ctx = ctx;
    await refreshWorkspace(ctx);
    render();
    await connect();
  },
  async onUiEvent(_ctx, event) {
    if (event.panelId !== PANEL_ID) return;
    if (event.nodeId === "codex-input" && event.type === "changed") {
      state.draft =
        typeof event.payload?.value === "string" ? event.payload.value : "";
      return;
    }
    if (event.type === "send" || event.nodeId === "codex-send") {
      await submitText(state.draft);
      return;
    }
    if (event.type === "retry" || event.nodeId === "codex-status") {
      await connect();
      return;
    }
    if (event.nodeId === "codex-stop") {
      await interruptTurn();
      return;
    }
    if (event.nodeId === "codex-new-thread") {
      if (state.activeTurnId) {
        state.error = "Stop the active turn before starting a new thread.";
      } else {
        state.activeThreadId = null;
        state.activeThreadPreview = "";
        state.messages = [];
        state.error = "";
      }
      scheduleRender({ immediate: true });
      return;
    }
    if (event.nodeId === "codex-toggle-history") {
      state.showHistory = !state.showHistory;
      if (state.showHistory && state.connection === "connected") {
        await refreshRecentThreads().catch((err) => {
          state.error = errorMessage(err);
        });
      }
      scheduleRender({ immediate: true });
      return;
    }
    if (event.nodeId === "codex-toggle-details") {
      state.showDetails = !state.showDetails;
      scheduleRender({ immediate: true });
      return;
    }
    if (event.type.startsWith("resume:")) {
      if (state.activeTurnId) {
        state.error = "Stop the active turn before switching threads.";
        scheduleRender({ immediate: true });
        return;
      }
      await resumeThread(event.type.slice("resume:".length)).catch((err) => {
        state.error = errorMessage(err);
        scheduleRender({ immediate: true });
      });
      return;
    }
    if (event.type.startsWith("approval:")) {
      const [, key, decision] = event.type.split(":");
      if (
        key &&
        new Set(["accept", "acceptForSession", "decline"]).has(decision)
      ) {
        await answerApproval(key, decision);
      }
    }
  },
  async onNotificationReply(_ctx, reply) {
    const targetThreadId =
      reply.context &&
      typeof reply.context === "object" &&
      typeof reply.context.threadId === "string"
        ? reply.context.threadId
        : "";
    if (
      targetThreadId &&
      targetThreadId !== state.activeThreadId &&
      !state.activeTurnId
    ) {
      await resumeThread(targetThreadId);
    }
    await submitText(reply.text);
  },
  async onWorkspaceActivated(ctx, workspace) {
    const previousCwd = state.cwd;
    await refreshWorkspace(ctx, workspace);
    if (state.cwd !== previousCwd) {
      if (state.activeTurnId) {
        state.resetThreadAfterTurn = true;
        state.error =
          "Workspace changed. The running turn will finish in its original workspace.";
      } else {
        state.activeThreadId = null;
        state.activeThreadPreview = "";
        state.messages = [];
        if (state.connection === "connected") {
          await refreshRecentThreads().catch((err) => {
            state.error = errorMessage(err);
          });
        }
      }
    }
    scheduleRender({ immediate: true });
  },
});

plugin.run();

function shutdown({ exit = false } = {}) {
  clearReconnectTimer();
  if (state.renderTimer !== null) {
    clearTimeout(state.renderTimer);
    state.renderTimer = null;
  }
  const client = state.client;
  state.client = null;
  client?.close();
  if (exit) setImmediate(() => process.exit(0));
}

process.once("SIGTERM", () => shutdown({ exit: true }));
process.once("SIGINT", () => shutdown({ exit: true }));
process.on("beforeExit", () => shutdown());
