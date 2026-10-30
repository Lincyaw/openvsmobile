import {
  chmodSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { inflateRawSync } from "node:zlib";
import type { IrohRelaySettings } from "../irohTransport.js";

export interface IrohTarget {
  ticket: string;
  alpn?: string;
  relay?: IrohRelaySettings;
}
export type Host = { token: string } & (
  | { url: string; iroh?: never }
  | { url?: never; iroh: IrohTarget }
);

function nonempty(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

export function validateHost(value: unknown): Host {
  const host = value as Host;
  if (!host || !nonempty(host.token)) throw new Error("Missing bearer token");
  if (!host.iroh) return { url: normalizeUrl(host.url!), token: host.token };
  if (
    host.url ||
    !nonempty(host.iroh.ticket) ||
    (host.iroh.alpn !== undefined && !nonempty(host.iroh.alpn))
  )
    throw new Error("Invalid Iroh target");
  const relay = host.iroh.relay;
  if (relay) {
    if (!["n0", "staging", "disabled", "custom"].includes(relay.mode))
      throw new Error("Invalid relay mode");
    if (relay.mode === "custom") {
      if (!Array.isArray(relay.relays) || !relay.relays.length)
        throw new Error("Missing custom relays");
      for (const entry of relay.relays) {
        const url = new URL(entry.url);
        if (
          !["https:", "http:"].includes(url.protocol) ||
          url.username ||
          url.password ||
          url.search ||
          url.hash ||
          (entry.quicPort !== undefined &&
            (!Number.isInteger(entry.quicPort) ||
              entry.quicPort < 1 ||
              entry.quicPort > 65535)) ||
          (entry.authToken !== undefined && !nonempty(entry.authToken))
        )
          throw new Error("Invalid custom relay");
      }
    }
  }
  return { token: host.token, iroh: host.iroh };
}

/** Accept the existing runtime/installer JSON or the app's QR pairing payload. */
export function importHost(input: string): Host {
  try {
    const text = input.trim();
    const decoded = text.startsWith("ovsm1.")
      ? inflateRawSync(Buffer.from(text.slice(6), "base64url"), {
          maxOutputLength: 1024 * 1024,
        }).toString("utf8")
      : text;
    const data = JSON.parse(decoded);
    if (!data.iroh) throw new Error();
    return validateHost({
      token: data.token,
      iroh: {
        ticket: data.iroh.ticket,
        alpn: data.iroh.alpn,
        relay: data.iroh.relay,
      },
    });
  } catch {
    throw new Error(
      "Invalid Iroh pairing data; expected runtime/installer JSON or an app pairing payload",
    );
  }
}
export interface ClientConfig {
  hosts: Record<string, Host>;
}

export function configPath(): string {
  return (
    process.env.OPENVSMOBILE_CLIENT_CONFIG ??
    join(
      process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"),
      "openvsmobile-next",
      "client.json",
    )
  );
}

export function normalizeUrl(value: string): string {
  const url = new URL(value);
  if (
    !["ws:", "wss:", "http:", "https:"].includes(url.protocol) ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  ) {
    throw new Error(
      "Use a ws(s) or http(s) URL without credentials, query or fragment",
    );
  }
  url.protocol =
    url.protocol === "https:" || url.protocol === "wss:" ? "wss:" : "ws:";
  if (url.pathname === "/") url.pathname = "/rpc";
  return url.toString();
}

export function loadConfig(path = configPath()): ClientConfig {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT")
      return { hosts: Object.create(null) };
    throw new Error("Cannot read client config");
  }
  try {
    const config = JSON.parse(raw) as ClientConfig;
    if (
      !config.hosts ||
      typeof config.hosts !== "object" ||
      Array.isArray(config.hosts)
    )
      throw new Error();
    for (const [name, host] of Object.entries(config.hosts)) {
      if (
        !/^[a-zA-Z0-9_-]+$/.test(name) ||
        !host ||
        typeof host.token !== "string" ||
        !host.token
      )
        throw new Error();
      config.hosts[name] = validateHost(host);
    }
    // Avoid prototype-dependent lookups for user-selected host aliases.
    config.hosts = Object.assign(Object.create(null), config.hosts);
    return config;
  } catch {
    throw new Error("Invalid client config; fix client.json before continuing");
  }
}

export function saveConfig(config: ClientConfig, path = configPath()): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temp = `${path}.${process.pid}.tmp`;
  writeFileSync(temp, JSON.stringify(config, null, 2) + "\n", { mode: 0o600 });
  chmodSync(temp, 0o600);
  renameSync(temp, path);
}
