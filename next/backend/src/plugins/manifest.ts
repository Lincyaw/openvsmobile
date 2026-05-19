// plugin.json parser. Reads the manifest subset we honor in v0 (issue C1),
// rejects malformed shapes, and round-trips unknown top-level keys forward
// so a future C2 parser doesn't have to re-discover them.
//
// The full §3.2 schema lands in C2 — see docs/design/mobile-code-platform.md.
// This parser is intentionally permissive on unknown keys (warn + carry
// through) and strict on the keys it actually uses.

import { readFile } from "node:fs/promises";
import { join } from "node:path";

export type EntryKind = "node" | "binary";

export interface ManifestEntry {
  kind: EntryKind;
  /// Path resolved by the host relative to the plugin directory. Stored as
  /// the raw string from the manifest so logs / errors point at what the
  /// author wrote. Use `resolveEntryPath()` to get the absolute path.
  path: string;
}

/// Capability declaration honored by the v0 host. `none` and `false` are
/// equivalent to "key absent" — the host treats both as "not declared".
export interface ManifestCapabilities {
  fs: "none" | "read" | "readwrite";
  terminal: boolean;
  network: boolean;
  secrets: boolean;
  ui: boolean;
}

export interface ManifestCommandStub {
  id: string;
  title: string;
}

export interface ManifestContributes {
  commands: ManifestCommandStub[];
  /// Anything inside `contributes` we don't recognize in v0 (panels,
  /// statusItems, …) is preserved verbatim so the C2 parser can pick it up
  /// without breaking installed plugins.
  unknown: Record<string, unknown>;
}

/// Plugin-level brand color (Batch 1 — §4.3 cross-cutting principles).
/// When set, the Flutter host scopes a Theme override around the plugin's
/// panels so the `brand` AccentToken resolves to this color inside the
/// panel only. Unset → the app's default brand color is used.
export type ManifestThemeColor =
  | "teal"
  | "blue"
  | "green"
  | "orange"
  | "red"
  | "purple"
  | "mono";

const THEME_COLORS: ReadonlySet<ManifestThemeColor> = new Set([
  "teal",
  "blue",
  "green",
  "orange",
  "red",
  "purple",
  "mono",
]);

export interface PluginManifest {
  id: string;
  name: string;
  version: string;
  entry: ManifestEntry;
  activation: string[];
  capabilities: ManifestCapabilities;
  contributes: ManifestContributes;
  /// Optional plugin-level brand color. Forwarded to the host via the
  /// `plugin.list` / `plugin.info` wire shape so the renderer can scope a
  /// theme override around the plugin's panels.
  themeColor?: ManifestThemeColor;
  /// Unknown top-level keys, kept verbatim (round-tripped forward).
  unknown: Record<string, unknown>;
}

export interface ManifestParseResult {
  manifest: PluginManifest;
  warnings: string[];
}

const KNOWN_TOP_LEVEL_KEYS = new Set([
  "id",
  "name",
  "version",
  "entry",
  "activation",
  "capabilities",
  "contributes",
  "themeColor",
]);

const KNOWN_CONTRIBUTES_KEYS = new Set(["commands"]);

const DEFAULT_CAPABILITIES: ManifestCapabilities = {
  fs: "none",
  terminal: false,
  network: false,
  secrets: false,
  ui: false,
};

export class ManifestError extends Error {}

/// Parse the `plugin.json` at `<dir>/plugin.json`. `dirId` is the canonical
/// id (the directory name); it overrides any mismatched `manifest.id` and is
/// logged as a warning when overruled.
export async function loadManifest(
  dir: string,
  dirId: string,
): Promise<ManifestParseResult> {
  const path = join(dir, "plugin.json");
  let raw: string;
  try {
    raw = await readFile(path, "utf8");
  } catch (err) {
    throw new ManifestError(
      `cannot read plugin.json at ${path}: ${(err as Error).message}`,
    );
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new ManifestError(
      `plugin.json at ${path} is not valid JSON: ${(err as Error).message}`,
    );
  }
  return parseManifestObject(parsed, dirId);
}

/// Pure parser — separated from the file read so tests can hit the validator
/// directly without writing a tempfile.
export function parseManifestObject(
  parsed: unknown,
  dirId: string,
): ManifestParseResult {
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new ManifestError("plugin.json must be a JSON object");
  }
  const bag = parsed as Record<string, unknown>;
  const warnings: string[] = [];

  // id: directory name wins. We still read it for diagnostics.
  let id = dirId;
  const rawId = bag.id;
  if (rawId !== undefined && rawId !== null) {
    if (typeof rawId !== "string" || rawId.length === 0) {
      throw new ManifestError(`id must be a non-empty string`);
    }
    if (rawId !== dirId) {
      warnings.push(
        `plugin.json id "${rawId}" does not match directory name "${dirId}"; directory name wins`,
      );
    }
  }

  const name = requireString(bag, "name");
  const version = requireString(bag, "version");
  const entry = parseEntry(bag.entry);
  const activation = parseActivation(bag.activation);
  const capabilities = parseCapabilities(bag.capabilities, warnings);
  const contributes = parseContributes(bag.contributes, warnings);
  const themeColor = parseThemeColor(bag.themeColor);

  const unknown: Record<string, unknown> = {};
  for (const key of Object.keys(bag)) {
    if (KNOWN_TOP_LEVEL_KEYS.has(key)) continue;
    unknown[key] = bag[key];
    warnings.push(`unknown top-level key "${key}" — preserved but ignored`);
  }

  const manifest: PluginManifest = {
    id,
    name,
    version,
    entry,
    activation,
    capabilities,
    contributes,
    unknown,
  };
  if (themeColor !== undefined) manifest.themeColor = themeColor;
  return { manifest, warnings };
}

function parseThemeColor(v: unknown): ManifestThemeColor | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "string" || !THEME_COLORS.has(v as ManifestThemeColor)) {
    throw new ManifestError(
      `themeColor must be one of ${[...THEME_COLORS].map((t) => `"${t}"`).join(" | ")}`,
    );
  }
  return v as ManifestThemeColor;
}

function requireString(bag: Record<string, unknown>, key: string): string {
  const v = bag[key];
  if (typeof v !== "string" || v.length === 0) {
    throw new ManifestError(`${key} must be a non-empty string`);
  }
  return v;
}

function parseEntry(v: unknown): ManifestEntry {
  if (!v || typeof v !== "object" || Array.isArray(v)) {
    throw new ManifestError(`entry must be an object`);
  }
  const e = v as Record<string, unknown>;
  const kind = e.kind;
  if (kind !== "node" && kind !== "binary") {
    throw new ManifestError(`entry.kind must be "node" or "binary"`);
  }
  const path = e.path;
  if (typeof path !== "string" || path.length === 0) {
    throw new ManifestError(`entry.path must be a non-empty string`);
  }
  return { kind, path };
}

/// Validate a single activation event against the documented grammar:
///   * `onStartup` (literal)
///   * `onCommand:<id>` where `<id>` is the contributed command id
///   * `onFileType:<ext>` where `<ext>` is a non-empty extension
/// Anything else is rejected with a manifest parse error. The grammar
/// is intentionally narrow — if a future activation event lands, widen
/// this function rather than letting arbitrary strings through.
function parseActivation(v: unknown): string[] {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v)) {
    throw new ManifestError(`activation must be a string array`);
  }
  const out: string[] = [];
  for (const item of v) {
    if (typeof item !== "string" || item.length === 0) {
      throw new ManifestError(`activation entries must be non-empty strings`);
    }
    validateActivationEvent(item);
    out.push(item);
  }
  return out;
}

function validateActivationEvent(event: string): void {
  if (event === "onStartup") return;
  const colon = event.indexOf(":");
  if (colon === -1) {
    throw new ManifestError(
      `activation event "${event}" is not recognized; expected "onStartup" | "onCommand:<id>" | "onFileType:<ext>"`,
    );
  }
  const prefix = event.substring(0, colon);
  const suffix = event.substring(colon + 1);
  if (suffix.length === 0) {
    throw new ManifestError(
      `activation event "${event}" has an empty argument after ":"`,
    );
  }
  if (prefix === "onCommand" || prefix === "onFileType") return;
  throw new ManifestError(
    `activation event "${event}" is not recognized; expected "onStartup" | "onCommand:<id>" | "onFileType:<ext>"`,
  );
}

function parseCapabilities(
  v: unknown,
  warnings: string[],
): ManifestCapabilities {
  if (v === undefined || v === null) return { ...DEFAULT_CAPABILITIES };
  if (typeof v !== "object" || Array.isArray(v)) {
    throw new ManifestError(`capabilities must be an object`);
  }
  const c = v as Record<string, unknown>;
  const out: ManifestCapabilities = { ...DEFAULT_CAPABILITIES };

  if (c.fs !== undefined && c.fs !== null) {
    if (c.fs !== "none" && c.fs !== "read" && c.fs !== "readwrite") {
      throw new ManifestError(
        `capabilities.fs must be "none" | "read" | "readwrite"`,
      );
    }
    out.fs = c.fs;
  }
  for (const key of ["terminal", "network", "secrets", "ui"] as const) {
    const val = c[key];
    if (val === undefined || val === null) continue;
    if (typeof val !== "boolean") {
      throw new ManifestError(`capabilities.${key} must be a boolean`);
    }
    out[key] = val;
  }
  for (const key of Object.keys(c)) {
    if (
      key !== "fs" &&
      key !== "terminal" &&
      key !== "network" &&
      key !== "secrets" &&
      key !== "ui"
    ) {
      warnings.push(`unknown capabilities key "${key}" — ignored`);
    }
  }
  return out;
}

function parseContributes(
  v: unknown,
  warnings: string[],
): ManifestContributes {
  const empty: ManifestContributes = { commands: [], unknown: {} };
  if (v === undefined || v === null) return empty;
  if (typeof v !== "object" || Array.isArray(v)) {
    throw new ManifestError(`contributes must be an object`);
  }
  const c = v as Record<string, unknown>;
  const commands: ManifestCommandStub[] = [];
  if (c.commands !== undefined && c.commands !== null) {
    if (!Array.isArray(c.commands)) {
      throw new ManifestError(`contributes.commands must be an array`);
    }
    for (const item of c.commands) {
      if (!item || typeof item !== "object" || Array.isArray(item)) {
        throw new ManifestError(`contributes.commands entries must be objects`);
      }
      const e = item as Record<string, unknown>;
      const id = e.id;
      const title = e.title;
      if (typeof id !== "string" || id.length === 0) {
        throw new ManifestError(`contributes.commands[].id must be a string`);
      }
      if (typeof title !== "string" || title.length === 0) {
        throw new ManifestError(`contributes.commands[].title must be a string`);
      }
      commands.push({ id, title });
    }
  }
  const unknown: Record<string, unknown> = {};
  for (const key of Object.keys(c)) {
    if (KNOWN_CONTRIBUTES_KEYS.has(key)) continue;
    unknown[key] = c[key];
    warnings.push(`unknown contributes key "${key}" — preserved but ignored`);
  }
  return { commands, unknown };
}

/// Resolve the entry path relative to the plugin directory. Used by the
/// process spawner so all path math lives in one place.
export function resolveEntryPath(dir: string, manifest: PluginManifest): string {
  return join(dir, manifest.entry.path);
}
