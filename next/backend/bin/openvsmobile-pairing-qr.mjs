#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { networkInterfaces, hostname } from "node:os";
import { basename } from "node:path";
import { pathToFileURL } from "node:url";
import { deflateRawSync } from "node:zlib";
import { createRequire } from "node:module";

export const PAIRING_KIND = "ovsm.backend";
export const COMPRESSED_PREFIX = "ovsm1.";
export const DEFAULT_ALPN = "openvsmobile.rpc.v1";

export function buildPairingPayload(runtime, options = {}) {
  const token = requiredString(runtime.token, "runtime.token");
  const version = optionalString(runtime.version);
  const name = options.name ?? hostname();
  const iroh = runtime.iroh;

  if (iroh && typeof iroh === "object" && typeof iroh.ticket === "string") {
    const payload = {
      v: 1,
      k: PAIRING_KIND,
      n: name,
      tr: "iroh",
      token,
      iroh: {
        ticket: requiredString(iroh.ticket, "runtime.iroh.ticket"),
        alpn: optionalString(iroh.alpn) ?? DEFAULT_ALPN,
      },
    };
    const endpointId = optionalString(iroh.endpointId);
    if (endpointId) payload.iroh.endpointId = endpointId;
    if (version) payload.version = version;
    return payload;
  }

  const port = requiredPort(runtime.port);
  const host = options.websocketHost ?? firstReachableHost() ?? hostname();
  const payload = {
    v: 1,
    k: PAIRING_KIND,
    n: name,
    tr: "websocket",
    token,
    ws: { host, port },
  };
  if (version) payload.version = version;
  return payload;
}

export function encodePairingPayload(payload) {
  const json = JSON.stringify(payload);
  const compressed = `${COMPRESSED_PREFIX}${deflateRawSync(json, {
    level: 9,
  }).toString("base64url")}`;
  return compressed.length + 8 < json.length ? compressed : json;
}

function requiredString(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${label} must be a non-empty string`);
  }
  return value;
}

function optionalString(value) {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function requiredPort(value) {
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    throw new Error("runtime.port must be a TCP port");
  }
  return value;
}

function firstReachableHost() {
  for (const entries of Object.values(networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.internal) continue;
      if (entry.family === "IPv4" && entry.address) return entry.address;
    }
  }
  for (const entries of Object.values(networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.internal) continue;
      if (entry.family === "IPv6" && entry.address) return entry.address;
    }
  }
  return undefined;
}

function usage() {
  return `Usage: ${basename(process.argv[1] ?? "openvsmobile-pairing-qr.mjs")} --runtime <runtime.json> [--version <expected>] [--host <host>] [--name <name>] [--payload-only] [--json-only]

Prints a terminal QR code containing the backend bearer token and either
Iroh ticket data or WebSocket host:port data. The QR payload is secret.
`;
}

function parseArgs(argv) {
  const out = {
    runtimePath: "",
    expectedVersion: undefined,
    websocketHost: undefined,
    name: undefined,
    payloadOnly: false,
    jsonOnly: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case "-h":
      case "--help":
        process.stdout.write(usage());
        process.exit(0);
      case "--runtime":
        out.runtimePath = argv[++i] ?? "";
        break;
      case "--version":
        out.expectedVersion = argv[++i];
        break;
      case "--host":
        out.websocketHost = argv[++i];
        break;
      case "--name":
        out.name = argv[++i];
        break;
      case "--payload-only":
        out.payloadOnly = true;
        break;
      case "--json-only":
        out.jsonOnly = true;
        break;
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (!out.runtimePath) throw new Error("missing --runtime <runtime.json>");
  return out;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const runtime = JSON.parse(readFileSync(args.runtimePath, "utf8"));
  if (
    args.expectedVersion &&
    runtime.version !== args.expectedVersion
  ) {
    throw new Error(
      `runtime version ${JSON.stringify(runtime.version)} does not match ${JSON.stringify(args.expectedVersion)}`,
    );
  }
  const payload = buildPairingPayload(runtime, {
    websocketHost: args.websocketHost,
    name: args.name,
  });
  if (args.jsonOnly) {
    process.stdout.write(`${JSON.stringify(payload)}\n`);
    return;
  }
  const encoded = encodePairingPayload(payload);
  if (args.payloadOnly) {
    process.stdout.write(`${encoded}\n`);
    return;
  }

  const require = createRequire(import.meta.url);
  const qrcode = require("qrcode-terminal");
  process.stdout.write(
    "Scan in MobileCode: Backends > Add backend > Scan QR\n",
  );
  process.stdout.write(
    "This QR contains the bearer token; treat it like a password.\n\n",
  );
  qrcode.generate(encoded, { small: true }, (qr) => {
    process.stdout.write(`${qr}\n`);
  });
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  try {
    main();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`openvsmobile-pairing-qr: ${message}\n`);
    process.exit(1);
  }
}
