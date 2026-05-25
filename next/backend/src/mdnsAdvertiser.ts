// mDNS service advertisement for LAN discovery.
//
// The backend advertises itself as `_openvsmobile._tcp` so Flutter clients on
// the same network can discover host+port without manual entry. The token is
// intentionally excluded from TXT records — the user must still enter it by
// hand (or paste from the backend's console output / runtime.json).

import { getResponder, CiaoService } from "@homebridge/ciao";
import { hostname } from "node:os";

const SERVICE_TYPE = "openvsmobile";

function defaultServiceName(): string {
  return hostname().replace(/\.local\.?$/i, "");
}

export interface MdnsAdvertiserDeps {
  port: number;
  version: string;
  serviceName?: string; // defaults to hostname
}

export class MdnsAdvertiser {
  private service?: CiaoService;
  private readonly deps: MdnsAdvertiserDeps;

  constructor(deps: MdnsAdvertiserDeps) {
    this.deps = deps;
  }

  async start(): Promise<void> {
    const responder = getResponder();
    this.service = responder.createService({
      name: this.deps.serviceName ?? defaultServiceName(),
      type: SERVICE_TYPE,
      port: this.deps.port,
      txt: {
        v: this.deps.version,
        port: String(this.deps.port),
      },
    });
    await this.service.advertise();
    console.error(
      `[openvsmobile-next] mDNS: advertising ${this.deps.serviceName ?? defaultServiceName()}._openvsmobile._tcp on port ${this.deps.port}`,
    );
  }

  async stop(): Promise<void> {
    if (this.service) {
      await this.service.end();
      this.service = undefined;
    }
  }
}
