// Backpressure tests for `safeSend`. The production path consults
// `ws.bufferedAmount` against `WS_SEND_HIGH_WATER_MARK` and terminates the
// peer when the buffer is past the cap, so a wedged client can't tip the
// backend into OOM. See src/wsSend.ts.

import { describe, expect, it, vi } from "vitest";
import type { WebSocket } from "ws";
import { safeSend, WS_SEND_HIGH_WATER_MARK } from "../src/wsSend.js";

function fakeSock(bufferedAmount: number, readyState = 1): {
  readyState: number;
  OPEN: number;
  bufferedAmount: number;
  send: ReturnType<typeof vi.fn>;
  terminate: ReturnType<typeof vi.fn>;
} {
  return {
    readyState,
    OPEN: 1,
    bufferedAmount,
    send: vi.fn(),
    terminate: vi.fn(),
  };
}

describe("safeSend backpressure", () => {
  it("sends normally when buffered amount is under the high water mark", () => {
    const ws = fakeSock(1024);
    const ok = safeSend(ws as unknown as WebSocket, "hello");
    expect(ok).toBe(true);
    expect(ws.send).toHaveBeenCalledWith("hello");
    expect(ws.terminate).not.toHaveBeenCalled();
  });

  it("terminates the peer when buffered amount exceeds the high water mark", () => {
    const ws = fakeSock(WS_SEND_HIGH_WATER_MARK + 1);
    // Silence the warn line for the duration of the call.
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const ok = safeSend(ws as unknown as WebSocket, "wedged");
      expect(ok).toBe(false);
      expect(ws.send).not.toHaveBeenCalled();
      expect(ws.terminate).toHaveBeenCalledTimes(1);
    } finally {
      warn.mockRestore();
    }
  });

  it("returns false without sending when the socket isn't OPEN", () => {
    const ws = fakeSock(0, 3); // CLOSED
    const ok = safeSend(ws as unknown as WebSocket, "msg");
    expect(ok).toBe(false);
    expect(ws.send).not.toHaveBeenCalled();
    expect(ws.terminate).not.toHaveBeenCalled();
  });

  it("treats missing bufferedAmount as zero (test-stub safety)", () => {
    const ws = {
      readyState: 1,
      OPEN: 1,
      send: vi.fn(),
      terminate: vi.fn(),
    };
    const ok = safeSend(ws as unknown as WebSocket, "msg");
    expect(ok).toBe(true);
    expect(ws.send).toHaveBeenCalledWith("msg");
  });
});
