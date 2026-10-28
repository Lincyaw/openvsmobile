import { describe, expect, it } from "vitest";
import { irohEnabled, resolveRelaySettings } from "../src/irohTransport.js";

describe("irohEnabled", () => {
  it("defaults to enabled when the env var is unset or empty", () => {
    expect(irohEnabled({})).toBe(true);
    expect(irohEnabled({ OPENVSMOBILE_IROH: "" })).toBe(true);
  });

  it("only disables Iroh for explicit false-like values", () => {
    for (const value of ["0", "false", "off", "no", " FALSE "]) {
      expect(irohEnabled({ OPENVSMOBILE_IROH: value })).toBe(false);
    }
  });

  it("treats any other non-empty value as enabled", () => {
    for (const value of ["1", "true", "on", "yes", "dev"]) {
      expect(irohEnabled({ OPENVSMOBILE_IROH: value })).toBe(true);
    }
  });
});

describe("resolveRelaySettings", () => {
  it("defaults to n0 relays + discovery", () => {
    expect(resolveRelaySettings({})).toEqual({ mode: "n0" });
    expect(resolveRelaySettings({ OPENVSMOBILE_IROH_RELAY_MODE: "n0" })).toEqual({
      mode: "n0",
    });
  });

  it("maps disabled aliases and staging", () => {
    for (const value of ["disabled", "off", "none"]) {
      expect(resolveRelaySettings({ OPENVSMOBILE_IROH_RELAY_MODE: value })).toEqual({
        mode: "disabled",
      });
    }
    expect(resolveRelaySettings({ OPENVSMOBILE_IROH_RELAY_MODE: "staging" })).toEqual({
      mode: "staging",
    });
  });

  it("custom relay URLs win over the mode and get QAD only over https", () => {
    expect(
      resolveRelaySettings({
        OPENVSMOBILE_IROH_RELAY_MODE: "default",
        OPENVSMOBILE_IROH_RELAY_URLS: "https://relay.corp, http://10.1.2.3:3340",
      }),
    ).toEqual({
      mode: "custom",
      relays: [
        { url: "https://relay.corp/", quicPort: 7842 },
        { url: "http://10.1.2.3:3340/" },
      ],
    });
  });

  it("honours an explicit QUIC port and lets it be switched off", () => {
    expect(
      resolveRelaySettings({
        OPENVSMOBILE_IROH_RELAY_URLS: "https://relay.corp",
        OPENVSMOBILE_IROH_RELAY_QUIC_PORT: "9000",
      }),
    ).toEqual({ mode: "custom", relays: [{ url: "https://relay.corp/", quicPort: 9000 }] });
    expect(
      resolveRelaySettings({
        OPENVSMOBILE_IROH_RELAY_URLS: "https://relay.corp",
        OPENVSMOBILE_IROH_RELAY_QUIC_PORT: "off",
      }),
    ).toEqual({ mode: "custom", relays: [{ url: "https://relay.corp/" }] });
  });

  it("attaches the shared relay token to every custom relay", () => {
    expect(
      resolveRelaySettings({
        OPENVSMOBILE_IROH_RELAY_URLS: "https://a.corp,http://10.1.2.3:3340",
        OPENVSMOBILE_IROH_RELAY_TOKEN: " s3cret ",
      }),
    ).toEqual({
      mode: "custom",
      relays: [
        { url: "https://a.corp/", quicPort: 7842, authToken: "s3cret" },
        { url: "http://10.1.2.3:3340/", authToken: "s3cret" },
      ],
    });
  });

  it("rejects malformed config instead of falling back to n0", () => {
    expect(() =>
      resolveRelaySettings({ OPENVSMOBILE_IROH_RELAY_URLS: "relay.corp" }),
    ).toThrow(/invalid relay URL/);
    expect(() =>
      resolveRelaySettings({ OPENVSMOBILE_IROH_RELAY_URLS: "ftp://relay.corp" }),
    ).toThrow(/http:\/\/ or https:\/\//);
    expect(() =>
      resolveRelaySettings({
        OPENVSMOBILE_IROH_RELAY_URLS: "https://relay.corp",
        OPENVSMOBILE_IROH_RELAY_QUIC_PORT: "70000",
      }),
    ).toThrow(/QUIC_PORT/);
    expect(() => resolveRelaySettings({ OPENVSMOBILE_IROH_RELAY_MODE: "bogus" })).toThrow(
      /RELAY_MODE/,
    );
  });
});
