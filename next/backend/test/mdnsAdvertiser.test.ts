import { describe, expect, it } from "vitest";
import { MdnsAdvertiser } from "../src/mdnsAdvertiser.js";

describe("MdnsAdvertiser", () => {
  it("constructs without throwing", () => {
    const a = new MdnsAdvertiser({ port: 7860, version: "0.2.0" });
    expect(a).toBeDefined();
  });

  it("starts and stops without error", async () => {
    const a = new MdnsAdvertiser({ port: 7860, version: "0.2.0" });
    await a.start();
    await a.stop();
  });

  it("accepts a custom service name", () => {
    const a = new MdnsAdvertiser({
      port: 7860,
      version: "0.2.0",
      serviceName: "my-macbook",
    });
    expect(a).toBeDefined();
  });
});
