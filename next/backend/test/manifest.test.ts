// Unit tests for the plugin.json parser. Pure validation logic; no
// process spawn.

import { describe, expect, it } from "vitest";
import { parseManifestObject, ManifestError } from "../src/plugins/manifest.js";

describe("parseManifestObject", () => {
  it("accepts a minimal valid manifest", () => {
    const { manifest, warnings } = parseManifestObject(
      {
        id: "hello",
        name: "Hello",
        version: "0.0.1",
        entry: { kind: "node", path: "main.js" },
        activation: ["onStartup"],
      },
      "hello",
    );
    expect(manifest.id).toBe("hello");
    expect(manifest.entry).toEqual({ kind: "node", path: "main.js" });
    expect(manifest.activation).toEqual(["onStartup"]);
    expect(manifest.capabilities.fs).toBe("none");
    expect(manifest.capabilities.ui).toBe(false);
    expect(warnings).toEqual([]);
  });

  it("treats missing activation as lazy-only (empty array)", () => {
    const { manifest } = parseManifestObject(
      {
        name: "Hello",
        version: "0.0.1",
        entry: { kind: "node", path: "main.js" },
      },
      "hello",
    );
    expect(manifest.activation).toEqual([]);
  });

  it("warns + overrides id when plugin.json.id mismatches the directory name", () => {
    const { manifest, warnings } = parseManifestObject(
      {
        id: "claimed-name",
        name: "Hello",
        version: "0.0.1",
        entry: { kind: "node", path: "main.js" },
      },
      "actual-dir-name",
    );
    expect(manifest.id).toBe("actual-dir-name");
    expect(warnings.some((w) => w.includes("claimed-name"))).toBe(true);
  });

  it("rejects unknown entry.kind", () => {
    expect(() =>
      parseManifestObject(
        {
          name: "X",
          version: "0",
          entry: { kind: "wasm", path: "x.wasm" },
        },
        "x",
      ),
    ).toThrow(ManifestError);
  });

  it("preserves unknown top-level keys and warns about them", () => {
    const { manifest, warnings } = parseManifestObject(
      {
        name: "X",
        version: "0",
        entry: { kind: "node", path: "x.js" },
        protocolVersion: "1.0",
        secrets: ["foo"],
      },
      "x",
    );
    expect(manifest.unknown).toEqual({
      protocolVersion: "1.0",
      secrets: ["foo"],
    });
    expect(warnings.filter((w) => w.includes("protocolVersion")).length).toBe(1);
    expect(warnings.filter((w) => w.includes("secrets")).length).toBe(1);
  });

  it("round-trips unknown contributes keys verbatim", () => {
    const { manifest, warnings } = parseManifestObject(
      {
        name: "X",
        version: "0",
        entry: { kind: "node", path: "x.js" },
        contributes: {
          commands: [{ id: "x.do", title: "Do" }],
          panels: [{ id: "x.panel" }],
        },
      },
      "x",
    );
    expect(manifest.contributes.commands).toEqual([
      { id: "x.do", title: "Do" },
    ]);
    expect(manifest.contributes.unknown).toEqual({
      panels: [{ id: "x.panel" }],
    });
    expect(warnings.some((w) => w.includes("panels"))).toBe(true);
  });

  it("accepts capabilities.fs values { none, read, readwrite }", () => {
    for (const fs of ["none", "read", "readwrite"] as const) {
      const { manifest } = parseManifestObject(
        {
          name: "X",
          version: "0",
          entry: { kind: "node", path: "x.js" },
          capabilities: { fs, ui: true },
        },
        "x",
      );
      expect(manifest.capabilities.fs).toBe(fs);
      expect(manifest.capabilities.ui).toBe(true);
    }
  });

  it("rejects manifests that are not JSON objects", () => {
    expect(() => parseManifestObject([] as unknown, "x")).toThrow(
      ManifestError,
    );
    expect(() => parseManifestObject("oops" as unknown, "x")).toThrow(
      ManifestError,
    );
  });
});
