import { describe, expect, it } from "vitest";
import {
  isCiaoProbeMtuError,
  MdnsAdvertiser,
  mdnsEnabled,
} from "../src/mdnsAdvertiser.js";

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

  it("can be disabled through OPENVSMOBILE_MDNS", () => {
    expect(mdnsEnabled({})).toBe(true);
    expect(mdnsEnabled({ OPENVSMOBILE_MDNS: "0" })).toBe(false);
    expect(mdnsEnabled({ OPENVSMOBILE_MDNS: "off" })).toBe(false);
    expect(mdnsEnabled({ OPENVSMOBILE_MDNS: "1" })).toBe(true);
  });

  it("recognizes ciao probe MTU assertion errors", () => {
    const err = new Error(
      "Probe query packet exceeds the mtu size (1480>1440). Can't split probe queries at the moment!",
    );
    err.stack = `${err.name}: ${err.message}
    at DNSPacket.createDNSQueryPackets (/app/node_modules/@homebridge/ciao/lib/coder/DNSPacket.js:128:25)`;

    expect(isCiaoProbeMtuError(err)).toBe(true);
    expect(isCiaoProbeMtuError(new Error("different failure"))).toBe(false);
  });
});
