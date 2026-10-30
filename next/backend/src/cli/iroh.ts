import type { Endpoint } from "@number0/iroh";
import { IrohRpcSocket } from "../irohRpcSocket.js";
import type { IrohTarget } from "./config.js";

const CONNECT_TIMEOUT_MS = 15_000;
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;

/** Own the ephemeral endpoint along with its one RPC stream. */
export async function connectIroh(
  target: IrohTarget,
  signal: AbortSignal,
): Promise<IrohRpcSocket> {
  let endpoint: Endpoint | undefined;
  let cancelled = false;
  let timer: NodeJS.Timeout | undefined;
  let rejectCancelled: (error: Error) => void = () => {};
  const close = () => {
    cancelled = true;
    void endpoint?.close().catch(() => {});
  };
  const onAbort = () => {
    close();
    rejectCancelled(new Error("Iroh connection cancelled"));
  };
  signal.addEventListener("abort", onAbort, { once: true });
  try {
    const attempt = (async () => {
      const { default: iroh } = await import("@number0/iroh");
      const addr = iroh.EndpointTicket.fromString(target.ticket).endpointAddr();
      const builder = iroh.Endpoint.builder();
      const relay = target.relay ?? { mode: "n0" };
      if (relay.mode === "n0" || relay.mode === "staging") builder.applyN0();
      else builder.applyMinimal();
      switch (relay.mode) {
        case "n0":
          builder.relayMode(iroh.RelayMode.defaultMode());
          break;
        case "staging":
          builder.relayMode(iroh.RelayMode.staging());
          break;
        case "disabled":
          builder.relayMode(iroh.RelayMode.disabled());
          break;
        case "custom": {
          const map = iroh.RelayMap.empty();
          for (const entry of relay.relays) map.insert(entry);
          builder.relayMode(iroh.RelayMode.custom(map));
          break;
        }
      }
      endpoint = await builder.bind();
      if (cancelled) {
        await endpoint.close();
        throw new Error("Iroh connection cancelled");
      }
      const conn = await endpoint.connect(
        addr,
        Array.from(Buffer.from(target.alpn ?? "openvsmobile.rpc.v1")),
      );
      const stream = await conn.openBi();
      if (cancelled) {
        await endpoint.close();
        throw new Error("Iroh connection cancelled");
      }
      const socket = new IrohRpcSocket(stream, conn, MAX_RESPONSE_BYTES);
      socket.once("close", close);
      // RpcClient installs its message listeners before starting the read loop.
      return socket;
    })();
    return await Promise.race([
      attempt,
      new Promise<never>((_, reject) => {
        rejectCancelled = reject;
        timer = setTimeout(() => {
          close();
          reject(new Error("Iroh connection timed out"));
        }, CONNECT_TIMEOUT_MS);
        if (signal.aborted) onAbort();
      }),
    ]);
  } catch {
    close();
    // Native errors may include relay credentials; expose only a safe message.
    throw new Error(
      "Cannot connect over Iroh; check ticket, ALPN and relay settings",
    );
  } finally {
    clearTimeout(timer);
    signal.removeEventListener("abort", onAbort);
  }
}
