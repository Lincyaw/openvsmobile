// AgentM Gateway — an openvsmobile plugin that acts as a mobile chat-client
// peer for AgentM's v2 gateway wire protocol.
//
// This intentionally lives as a plugin, not core backend code. The phone sees
// a native plugin panel + replyable notifications; AgentM sees an ordinary
// gateway peer sending `inbound` envelopes and receiving `outbound` envelopes.

import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { Buffer } from "node:buffer";
import net from "node:net";

import { createPlugin, ui } from "@openvsmobile/sdk";

const PANEL_ID = "chat";
const WIRE_VERSION = 2;
const PEER_VERSION = "0.1.0";
const MAX_TRANSCRIPT_ITEMS = 80;
const MAX_VISIBLE_ACTIVITY_ITEMS = 5;
const RECONNECT_DELAY_MS = 2000;

const DURABLE_NOTIFICATION_KINDS = new Set([
  "assistant_text",
  "command_result",
  "approval_request",
  "diagnostic_warning",
  "diagnostic_error",
]);

function defaultConnectUrl() {
  const runtimeDir = process.env.XDG_RUNTIME_DIR;
  if (runtimeDir) return `unix://${runtimeDir}/agentm-gw.sock`;
  const uid = typeof process.getuid === "function" ? process.getuid() : "user";
  return `unix:///tmp/agentm-gw-${uid}.sock`;
}

function env(name, fallback = "") {
  const v = process.env[`OPENVSMOBILE_PLUGIN_${name}`];
  return typeof v === "string" && v.length > 0 ? v : fallback;
}

const config = {
  connect: env("AGENTM_CONNECT", defaultConnectUrl()),
  token: env("AGENTM_TOKEN"),
  cwd: env("AGENTM_CWD"),
  channel: env("AGENTM_CHANNEL", "openvsmobile"),
  chatId: env("AGENTM_CHAT_ID", "phone"),
  senderId: env("AGENTM_SENDER_ID", "openvsmobile"),
  senderName: env("AGENTM_SENDER_NAME", "OpenVS Mobile"),
  scenario: env("AGENTM_SCENARIO"),
};
config.sessionKey = env(
  "AGENTM_SESSION_KEY",
  `${config.channel}:${config.chatId}`,
);

const state = {
  ctx: null,
  client: null,
  status: "disconnected",
  error: "",
  draft: "",
  scenarioSent: false,
  welcome: null,
  cwd: "",
  workspaceLabel: "",
  lastStatus: "Not connected",
  lastReply: "",
  lastReplyKind: "",
  currentReply: "",
  turnHadVisibleReply: false,
  turnStartedAt: 0,
  showDetails: false,
  transcript: [],
  activeTurn: false,
  reconnectTimer: null,
  lastNotificationByKind: new Map(),
};

function nowSeconds() {
  return Date.now() / 1000;
}

function makeEnvelope(kind, body = {}, extra = {}) {
  return {
    v: WIRE_VERSION,
    id: randomUUID(),
    kind,
    ts: nowSeconds(),
    body,
    ...extra,
  };
}

function encodeEnvelope(env) {
  const body = Buffer.from(JSON.stringify(env), "utf8");
  const header = Buffer.allocUnsafe(4);
  header.writeUInt32BE(body.length, 0);
  return Buffer.concat([header, body]);
}

function decodeFrames(buffer) {
  const frames = [];
  let offset = 0;
  while (buffer.length - offset >= 4) {
    const len = buffer.readUInt32BE(offset);
    const end = offset + 4 + len;
    if (buffer.length < end) break;
    const payload = JSON.parse(buffer.subarray(offset + 4, end).toString("utf8"));
    frames.push(payload);
    offset = end;
  }
  return { frames, rest: buffer.subarray(offset) };
}

function decodeOneFrame(bytes) {
  const buffer = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes);
  const { frames } = decodeFrames(buffer);
  if (frames.length === 0) throw new Error("AgentM frame was empty");
  return frames[0];
}

class AgentMWireClient extends EventEmitter {
  constructor(options) {
    super();
    this.options = options;
    this.transport = null;
    this.mode = null;
    this.buffer = Buffer.alloc(0);
    this.connected = false;
    this.closed = false;
    this.welcomeReceived = false;
  }

  connect() {
    if (this.options.connect.startsWith("unix://")) {
      this.connectUnix(this.options.connect.slice("unix://".length));
      return;
    }
    if (
      this.options.connect.startsWith("ws://") ||
      this.options.connect.startsWith("wss://")
    ) {
      this.connectWebSocket(this.options.connect);
      return;
    }
    throw new Error(`unsupported AgentM connect URL: ${this.options.connect}`);
  }

  connectUnix(path) {
    this.mode = "unix";
    const socket = net.createConnection(path);
    this.transport = socket;
    socket.on("connect", () => this.sendHello());
    socket.on("data", (chunk) => this.onBytes(chunk));
    socket.on("error", (err) => this.fail(err));
    socket.on("close", () => this.onClosed());
  }

  connectWebSocket(url) {
    if (typeof WebSocket !== "function") {
      throw new Error("Node runtime does not expose WebSocket");
    }
    this.mode = "websocket";
    const ws = new WebSocket(url);
    this.transport = ws;
    ws.binaryType = "arraybuffer";
    ws.addEventListener("open", () => this.sendHello());
    ws.addEventListener("message", (event) => {
      const data = event.data;
      if (data instanceof ArrayBuffer) {
        this.onEnvelope(decodeOneFrame(data));
      } else if (ArrayBuffer.isView(data)) {
        this.onEnvelope(decodeOneFrame(data.buffer));
      } else {
        this.fail(new Error("AgentM WebSocket sent a non-binary message"));
      }
    });
    ws.addEventListener("error", () => this.fail(new Error("WebSocket error")));
    ws.addEventListener("close", () => this.onClosed());
  }

  sendHello() {
    const body = {
      peer_name: "openvsmobile",
      peer_version: PEER_VERSION,
      capabilities: {
        ui: "native",
        notifications: true,
        reply: true,
      },
    };
    if (config.token) body.auth = { token: config.token };
    if (state.cwd) body.cwd = state.cwd;
    this.send(makeEnvelope("hello", body));
  }

  onBytes(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    const decoded = decodeFrames(this.buffer);
    this.buffer = decoded.rest;
    for (const env of decoded.frames) this.onEnvelope(env);
  }

  onEnvelope(env) {
    if (!env || typeof env !== "object") return;
    if (env.kind === "welcome") {
      this.welcomeReceived = true;
      this.connected = true;
      this.emit("welcome", env);
      return;
    }
    if (env.kind === "ping") {
      this.send(makeEnvelope("pong", {}));
      return;
    }
    if (env.kind === "outbound" || env.kind === "error") {
      this.emit("message", env);
    }
  }

  send(env) {
    if (!this.transport || this.closed) {
      throw new Error("AgentM transport is not connected");
    }
    const frame = encodeEnvelope(env);
    if (this.mode === "unix") {
      this.transport.write(frame);
      return;
    }
    if (this.transport.readyState !== WebSocket.OPEN) {
      throw new Error("AgentM WebSocket is not open");
    }
    this.transport.send(frame);
  }

  close() {
    this.closed = true;
    if (!this.transport) return;
    if (this.mode === "unix") this.transport.destroy();
    else this.transport.close();
  }

  fail(err) {
    this.emit("error", err);
  }

  onClosed() {
    if (this.closed) return;
    this.connected = false;
    this.emit("close");
  }
}

function appendTranscript(role, text, meta = {}) {
  const trimmed = String(text || "").trim();
  if (!trimmed && !meta.kind) return;
  state.transcript.push({
    id: randomUUID(),
    role,
    text: trimmed,
    kind: meta.kind || "",
    ts: Date.now(),
  });
  if (state.transcript.length > MAX_TRANSCRIPT_ITEMS) {
    state.transcript.splice(0, state.transcript.length - MAX_TRANSCRIPT_ITEMS);
  }
}

function setLastReply(text, kind = "assistant_text") {
  const trimmed = String(text || "").trim();
  if (!trimmed) return;
  state.lastReply = trimmed;
  state.lastReplyKind = kind;
}

function resetTurnReply() {
  state.currentReply = "";
  state.turnHadVisibleReply = false;
}

function appendCurrentReply(text, kind = "stream_text") {
  const chunk = String(text || "");
  if (!chunk) return;
  state.currentReply += chunk;
  state.turnHadVisibleReply = true;
  setLastReply(state.currentReply, kind);
}

function setVisibleReply(text, kind) {
  const trimmed = String(text || "").trim();
  if (!trimmed) return;
  state.currentReply = trimmed;
  state.turnHadVisibleReply = true;
  setLastReply(trimmed, kind);
}

function currentStatusText() {
  if (state.status === "connecting") return "Connecting to AgentM gateway.";
  if (state.status !== "connected") {
    return state.error
      ? `Disconnected. ${state.error}`
      : "Disconnected from AgentM gateway.";
  }
  if (state.lastStatus) return state.lastStatus;
  if (state.activeTurn) return "AgentM is working. Wait for the reply or stop this turn.";
  return "Connected. Ready for your next message.";
}

function latestReplyText() {
  if (state.lastReply) return state.lastReply;
  if (state.activeTurn) return "No reply yet. AgentM is still working.";
  return "No AgentM reply yet.";
}

function visibleActivity() {
  return state.transcript.slice(-MAX_VISIBLE_ACTIVITY_ITEMS);
}

function outboundKind(env) {
  const meta = env?.body?.metadata;
  return meta && typeof meta.kind === "string" ? meta.kind : "";
}

function outboundContent(env) {
  const content = env?.body?.content;
  return typeof content === "string" ? content : "";
}

function titleForKind(kind) {
  switch (kind) {
    case "assistant_text":
      return "AgentM replied";
    case "command_result":
      return "AgentM command result";
    case "approval_request":
      return "AgentM needs input";
    case "diagnostic_warning":
      return "AgentM warning";
    case "diagnostic_error":
      return "AgentM error";
    default:
      return "AgentM update";
  }
}

async function notifyOutbound(env) {
  if (!state.ctx) return;
  const kind = outboundKind(env);
  if (!DURABLE_NOTIFICATION_KINDS.has(kind)) return;
  const content = outboundContent(env);
  const text = content.trim();
  if (!text) return;
  const previousId = state.lastNotificationByKind.get(kind);
  const input = {
    level: kind === "diagnostic_error" ? "error" : kind === "diagnostic_warning" ? "warning" : "info",
    title: titleForKind(kind),
    body: text,
    spoken: {
      title: titleForKind(kind),
      body: text,
    },
    reply: {
      event: "agentm.reply",
      context: {
        sessionKey: config.sessionKey,
        channel: config.channel,
        chatId: config.chatId,
      },
      placeholder: "Reply to AgentM",
    },
    groupKey: `agentm:${config.sessionKey}`,
  };
  if (previousId) input.supersedes = previousId;
  try {
    const result = await state.ctx.showNotification(input);
    if (result?.id) state.lastNotificationByKind.set(kind, result.id);
  } catch (err) {
    state.ctx.log("warn", `AgentM notification failed: ${err.message ?? String(err)}`);
  }
}

function handleOutbound(env) {
  const kind = outboundKind(env);
  const content = outboundContent(env);
  switch (kind) {
    case "turn_start":
      state.activeTurn = true;
      resetTurnReply();
      state.turnStartedAt = Date.now();
      state.lastStatus = "Message accepted. AgentM is working.";
      appendTranscript("system", "Turn started", { kind });
      break;
    case "stream_text":
    case "stream_thinking":
      if (kind === "stream_text") {
        appendCurrentReply(content, kind);
        state.lastStatus = "AgentM is replying.";
      }
      appendTranscript(kind === "stream_thinking" ? "thinking" : "assistant", content, { kind });
      break;
    case "assistant_text":
      state.activeTurn = false;
      state.lastStatus = "AgentM replied.";
      setVisibleReply(content, kind);
      appendTranscript("assistant", content, { kind });
      break;
    case "command_result":
      state.activeTurn = false;
      state.lastStatus = "Command result received.";
      setVisibleReply(content, kind);
      appendTranscript("system", content, { kind });
      break;
    case "approval_request":
      state.activeTurn = false;
      state.lastStatus = "AgentM needs input.";
      setVisibleReply(content || "Approval requested", kind);
      appendTranscript("system", content || "Approval requested", { kind });
      break;
    case "diagnostic_warning":
      state.lastStatus = "AgentM warning.";
      setVisibleReply(content, kind);
      appendTranscript("warning", content, { kind });
      break;
    case "diagnostic_error":
      state.activeTurn = false;
      state.lastStatus = "AgentM error.";
      setVisibleReply(content, kind);
      appendTranscript("error", content, { kind });
      break;
    case "agent_end":
      state.activeTurn = false;
      state.turnStartedAt = 0;
      if (!state.turnHadVisibleReply) {
        state.lastStatus = "Turn finished without a visible reply.";
      }
      appendTranscript("system", "Turn finished", { kind });
      break;
    case "request_ack":
      state.lastStatus = "Message accepted. Waiting for AgentM.";
      appendTranscript("system", "Message accepted", { kind });
      break;
    default:
      if (content) appendTranscript("system", content, { kind });
      break;
  }
  void notifyOutbound(env);
  render();
}

function handleGatewayError(env) {
  const msg =
    typeof env?.body?.message === "string" ? env.body.message : "AgentM gateway error";
  state.error = msg;
  state.activeTurn = false;
  state.lastStatus = "AgentM gateway error.";
  appendTranscript("error", msg, { kind: "error" });
  render();
}

function sendInbound(partial) {
  if (!state.client?.connected) {
    state.error = "AgentM gateway is not connected";
    render();
    return false;
  }
  const body = {
    channel: config.channel,
    chat_id: config.chatId,
    sender_id: config.senderId,
    sender_name: config.senderName,
    ...partial,
  };
  const extra = { session_key: config.sessionKey };
  if (!state.scenarioSent && config.scenario) {
    extra.scenario = config.scenario;
    state.scenarioSent = true;
  }
  state.client.send(makeEnvelope("inbound", body, extra));
  return true;
}

function submitText(text) {
  const content = String(text || "").trim();
  if (!content) return false;
  const isCommand = content.startsWith("/") && !content.startsWith("//");
  const ok = sendInbound({
    content,
    action: isCommand ? "run_command" : "submit",
    ...(isCommand ? {} : { policy: "interrupt_first" }),
    request_id: randomUUID(),
  });
  if (ok) {
    appendTranscript("user", content, { kind: "submit" });
    state.activeTurn = true;
    resetTurnReply();
    state.lastStatus = "Sent. Waiting for AgentM.";
    state.turnStartedAt = Date.now();
    state.draft = "";
    render();
  }
  return ok;
}

function interrupt() {
  const ok = sendInbound({ control: "interrupt", request_id: randomUUID() });
  if (ok) {
    state.activeTurn = false;
    state.turnStartedAt = 0;
    state.lastStatus = "Stop requested.";
    appendTranscript("system", "Stop requested", { kind: "interrupt" });
    render();
  }
}

async function announceLast() {
  if (!state.ctx) return;
  const body = latestReplyText();
  try {
    await state.ctx.showNotification({
      level: state.lastReplyKind === "diagnostic_error" ? "error" : "info",
      title: state.lastReply ? "AgentM last message" : "AgentM status",
      body,
      spoken: {
        title: state.lastReply ? "AgentM last message" : "AgentM status",
        body,
      },
      reply: {
        event: "agentm.reply",
        context: {
          sessionKey: config.sessionKey,
          channel: config.channel,
          chatId: config.chatId,
        },
        placeholder: "Reply to AgentM",
      },
      groupKey: `agentm:${config.sessionKey}:read-last`,
    });
  } catch (err) {
    state.ctx.log("warn", `AgentM read-last notification failed: ${err.message ?? String(err)}`);
  }
}

function scheduleReconnect() {
  if (state.reconnectTimer !== null) return;
  state.reconnectTimer = setTimeout(() => {
    state.reconnectTimer = null;
    connect();
  }, RECONNECT_DELAY_MS);
  if (typeof state.reconnectTimer.unref === "function") {
    state.reconnectTimer.unref();
  }
}

function connect() {
  if (state.client) {
    try {
      state.client.close();
    } catch {
      // best-effort close before replacing the client.
    }
  }
  state.status = "connecting";
  state.lastStatus = "Connecting to AgentM gateway.";
  state.error = "";
  render();
  const client = new AgentMWireClient(config);
  state.client = client;
  client.on("welcome", (env) => {
    state.status = "connected";
    state.error = "";
    state.welcome = env.body || {};
    state.lastStatus = "Connected. Ready for your next message.";
    appendTranscript("system", "Connected to AgentM gateway", { kind: "welcome" });
    render();
  });
  client.on("message", (env) => {
    if (env.kind === "error") handleGatewayError(env);
    else handleOutbound(env);
  });
  client.on("error", (err) => {
    state.status = "disconnected";
    state.error = err.message || String(err);
    state.activeTurn = false;
    state.lastStatus = "Disconnected from AgentM gateway.";
    render();
  });
  client.on("close", () => {
    state.status = "disconnected";
    if (!state.error) state.error = "AgentM gateway connection closed";
    state.activeTurn = false;
    state.lastStatus = "Disconnected from AgentM gateway.";
    render();
    scheduleReconnect();
  });
  try {
    client.connect();
  } catch (err) {
    state.status = "disconnected";
    state.error = err.message || String(err);
    state.activeTurn = false;
    state.lastStatus = "Disconnected from AgentM gateway.";
    render();
    scheduleReconnect();
  }
}

async function refreshCwd(ctx, workspace = undefined) {
  if (config.cwd) {
    state.cwd = config.cwd;
    state.workspaceLabel = "configured";
    return;
  }
  try {
    const ws = workspace === undefined ? await ctx.currentWorkspace() : workspace;
    if (ws?.root) {
      state.cwd = ws.root;
      state.workspaceLabel = ws.label || ws.root;
      return;
    }
  } catch (err) {
    state.error = `Could not read current workspace: ${err.message ?? String(err)}`;
  }
  try {
    state.cwd = process.cwd();
  } catch {
    state.cwd = "";
  }
  state.workspaceLabel = "plugin";
}

function statusAccent() {
  if (state.status === "connected") return "success";
  if (state.status === "connecting") return "info";
  return "warning";
}

function roleLabel(item) {
  switch (item.role) {
    case "user":
      return "You";
    case "assistant":
      return "AgentM";
    case "thinking":
      return "Thinking";
    case "warning":
      return "Warning";
    case "error":
      return "Error";
    default:
      return "System";
  }
}

function transcriptNode(item, index) {
  const title = `${roleLabel(item)}${item.kind ? ` · ${item.kind}` : ""}`;
  return ui.withMetadata(
    ui.listTile({
      id: `msg-${item.id}`,
      title,
      subtitle: item.text || item.kind,
    }),
    {
      accessibilityLabel: title,
      spokenValue: item.text || item.kind,
      focusRole: item.role === "assistant" ? "status" : undefined,
      focusOrder: 20 + index,
    },
  );
}

function actionButton({ id, label, style, order, hint }) {
  return ui.withMetadata(
    ui.button({ id, label, style }),
    {
      accessibilityLabel: label,
      accessibilityHint: hint,
      focusRole: style === "danger" ? "danger" : "action",
      focusOrder: order,
    },
  );
}

function buildTree() {
  const statusText = currentStatusText();
  const replyText = latestReplyText();
  const activity = visibleActivity();
  const children = [
    ui.withMetadata(
      ui.banner({
        id: "agentm-status",
        title: state.status === "connected" ? "Connected" : state.status === "connecting" ? "Connecting" : "Disconnected",
        body: statusText,
        accent: statusAccent(),
        action: state.status === "connected" ? undefined : { label: "Retry", eventId: "reconnect" },
      }),
      {
        accessibilityLabel: "AgentM status",
        spokenValue: statusText,
        focusRole: "status",
        focusOrder: 0,
      },
    ),
    ui.section({
      id: "agentm-blind-controls",
      title: "Blind controls",
      variant: "inset",
      children: [
        ui.withMetadata(
          ui.text({
            id: "agentm-live-status",
            text: statusText,
            style: "title",
          }),
          {
            accessibilityLabel: "Current AgentM state",
            spokenValue: statusText,
            focusRole: "status",
            focusOrder: 1,
          },
        ),
        ...(state.activeTurn
          ? [
              ui.progress({
                id: "agentm-active-turn",
                label: "Waiting for AgentM",
                variant: "linear",
                accent: "info",
              }),
            ]
          : []),
        ui.withMetadata(
          ui.text({
            id: "agentm-last-reply",
            text: replyText,
            style: state.lastReply ? "body" : "caption",
          }),
          {
            accessibilityLabel: state.lastReply ? "Last AgentM message" : "Last AgentM message is empty",
            spokenValue: replyText,
            focusRole: "status",
            focusOrder: 2,
          },
        ),
        ui.withMetadata(
          ui.textField({
            id: "agentm-input",
            label: "Message",
            value: state.draft,
            placeholder: "Type or dictate",
          }),
          {
            accessibilityLabel: "Message to AgentM",
            accessibilityHint: "Type or dictate a message",
            focusRole: "input",
            focusOrder: 3,
            voiceInputEvent: "send",
          },
        ),
        ui.column({
          id: "agentm-action-buttons",
          gap: "sm",
          children: [
            actionButton({
              id: "agentm-send",
              label: "Send message",
              style: "primary",
              order: 4,
              hint: "Sends the message to AgentM",
            }),
            actionButton({
              id: "agentm-interrupt",
              label: "Stop current turn",
              style: "danger",
              order: 5,
              hint: "Stops the current AgentM turn",
            }),
            actionButton({
              id: "agentm-read-last",
              label: "Read last reply",
              style: "secondary",
              order: 6,
              hint: "Reads the latest AgentM reply through a notification",
            }),
          ],
        }),
      ],
    }),
  ];

  children.push(
    ui.section({
      id: "agentm-activity",
      title: "Recent activity",
      children:
        activity.length === 0
          ? [
              ui.text({
                id: "agentm-empty",
                text: "No activity yet.",
                style: "caption",
              }),
            ]
          : activity.map(transcriptNode),
    }),
  );

  children.push(
    actionButton({
      id: "agentm-toggle-details",
      label: state.showDetails ? "Hide details" : "Show details",
      style: "secondary",
      order: 30,
      hint: "Shows or hides connection diagnostics",
    }),
  );

  if (state.showDetails) {
    children.push(
      ui.section({
        id: "agentm-details",
        title: "Connection",
        children: [
          ui.text({ id: "agentm-connect-url", text: config.connect, style: "mono" }),
          ui.text({ id: "agentm-cwd", text: `cwd ${state.cwd || "(unset)"}`, style: "mono" }),
          ui.text({ id: "agentm-session-key", text: config.sessionKey, style: "mono" }),
          ui.text({
            id: "agentm-server-version",
            text: `server ${state.welcome?.server_version ?? "unknown"}`,
            style: "caption",
          }),
        ],
      }),
    );
  }

  return ui.column({ id: "agentm-root", gap: "md", children });
}

function render() {
  if (!state.ctx) return;
  state.ctx.renderPanel(PANEL_ID, buildTree());
}

const plugin = createPlugin({
  async onActivate(ctx) {
    state.ctx = ctx;
    await refreshCwd(ctx);
    render();
    connect();
  },
  onUiEvent(_ctx, event) {
    if (event.nodeId === "agentm-input" && event.type === "changed") {
      const v = event.payload?.value;
      state.draft = typeof v === "string" ? v : "";
      render();
      return;
    }
    const eventId = event.type || event.nodeId;
    if (eventId === "send" || event.nodeId === "agentm-send") {
      submitText(state.draft);
      return;
    }
    if (eventId === "reconnect") {
      connect();
      return;
    }
    if (event.nodeId === "agentm-read-last") {
      void announceLast();
      return;
    }
    if (event.nodeId === "agentm-toggle-details") {
      state.showDetails = !state.showDetails;
      render();
      return;
    }
    if (event.nodeId === "agentm-interrupt") {
      interrupt();
    }
  },
  onNotificationReply(_ctx, reply) {
    submitText(reply.text);
  },
  async onWorkspaceActivated(ctx, workspace) {
    const oldCwd = state.cwd;
    await refreshCwd(ctx, workspace);
    if (state.cwd !== oldCwd) {
      appendTranscript("system", `Workspace: ${state.workspaceLabel}`, {
        kind: "workspace",
      });
      render();
      connect();
    }
  },
});

plugin.run();

function shutdown({ exit = false } = {}) {
  if (state.reconnectTimer !== null) {
    clearTimeout(state.reconnectTimer);
    state.reconnectTimer = null;
  }
  if (state.client) {
    state.client.close();
    state.client = null;
  }
  if (exit) {
    setImmediate(() => process.exit(0));
  }
}

process.once("SIGTERM", () => shutdown({ exit: true }));
process.once("SIGINT", () => shutdown({ exit: true }));
process.on("beforeExit", () => shutdown());
