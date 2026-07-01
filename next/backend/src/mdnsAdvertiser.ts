// mDNS service advertisement for LAN discovery.
//
// The backend advertises itself as `_openvsmobile._tcp` so Flutter clients on
// the same network can discover host+port without manual entry. The token is
// intentionally excluded from TXT records — the user must still enter it by
// hand (or paste from the backend's console output / runtime.json).

import { getResponder, CiaoService, type Responder } from "@homebridge/ciao";
import { hostname } from "node:os";

const SERVICE_TYPE = "openvsmobile";
const CIAO_PROBE_MTU_MESSAGE = "Probe query packet exceeds the mtu size";
const DISABLED_MDNS_VALUES = new Set(["0", "false", "no", "off"]);

const responderOptions = {
  // LAN discovery is best-effort; IPv4 is enough for the Android bootstrap
  // path and keeps ciao's single-packet probe under the multicast MTU on
  // machines with many Docker/VPN/IPv6 addresses.
  disableIpv6: true,
  advertiseIpv6: false,
  excludeIpv6Only: true,
};

function defaultServiceName(): string {
  return hostname().replace(/\.local\.?$/i, "");
}

export function mdnsEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const raw = env.OPENVSMOBILE_MDNS;
  return raw === undefined || !DISABLED_MDNS_VALUES.has(raw.toLowerCase());
}

export function isCiaoProbeMtuError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  if (!error.message.includes(CIAO_PROBE_MTU_MESSAGE)) return false;
  const stack = error.stack ?? "";
  return stack === "" || stack.includes("@homebridge/ciao");
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export interface MdnsAdvertiserDeps {
  port: number;
  version: string;
  serviceName?: string; // defaults to hostname
}

export class MdnsAdvertiser {
  private service?: CiaoService;
  private responder?: Responder;
  private readonly deps: MdnsAdvertiserDeps;
  private disabled = false;
  private guardInstalled = false;

  constructor(deps: MdnsAdvertiserDeps) {
    this.deps = deps;
  }

  async start(): Promise<void> {
    if (!mdnsEnabled()) {
      console.error(
        "[openvsmobile-next] mDNS: disabled by OPENVSMOBILE_MDNS",
      );
      return;
    }
    if (this.service) return;

    this.installCiaoCrashGuard();
    const responder = getResponder(responderOptions);
    this.responder = responder;
    const serviceName = this.deps.serviceName ?? defaultServiceName();
    this.service = responder.createService({
      name: serviceName,
      type: SERVICE_TYPE,
      port: this.deps.port,
      disabledIpv6: true,
      txt: {
        v: this.deps.version,
        port: String(this.deps.port),
      },
    });
    try {
      await this.service.advertise();
    } catch (error) {
      if (!this.disabled) {
        await this.disable(`advertise failed: ${errorMessage(error)}`);
      }
      return;
    }
    if (this.disabled) return;
    console.error(
      `[openvsmobile-next] mDNS: advertising ${serviceName}._openvsmobile._tcp on port ${this.deps.port}`,
    );
  }

  async stop(): Promise<void> {
    this.removeCiaoCrashGuard();
    const service = this.service;
    const responder = this.responder;
    this.service = undefined;
    this.responder = undefined;
    if (service) {
      await service.end().catch(() => {});
    }
    if (responder) {
      await responder.shutdown().catch(() => {});
    }
  }

  private installCiaoCrashGuard(): void {
    if (this.guardInstalled) return;
    process.prependListener("uncaughtException", this.handleUncaughtException);
    this.guardInstalled = true;
  }

  private removeCiaoCrashGuard(): void {
    if (!this.guardInstalled) return;
    process.off("uncaughtException", this.handleUncaughtException);
    this.guardInstalled = false;
  }

  private readonly handleUncaughtException = (error: Error): void => {
    if (!isCiaoProbeMtuError(error)) {
      this.removeCiaoCrashGuard();
      throw error;
    }
    void this.disable(`ciao probe packet exceeded MTU: ${error.message}`);
  };

  private async disable(reason: string): Promise<void> {
    if (this.disabled) return;
    this.disabled = true;
    console.error(
      `[openvsmobile-next] mDNS disabled: ${reason}; backend will continue without LAN discovery`,
    );
    await this.stop();
  }
}
