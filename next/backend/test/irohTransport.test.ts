import { describe, expect, it } from "vitest";
import { irohEnabled } from "../src/irohTransport.js";

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
