// Unit tests for the stdio JSON-RPC frame codec. The host has to be
// tolerant of both LSP-style Content-Length framing and bare newline-
// delimited JSON; these tests pin the autodetect transitions.

import { describe, expect, it } from "vitest";
import { FrameCodec } from "../src/plugins/framing.js";

function collect(): {
  codec: FrameCodec;
  messages: unknown[];
  framingErrors: string[];
} {
  const messages: unknown[] = [];
  const framingErrors: string[] = [];
  const codec = new FrameCodec({
    onMessage: (m) => messages.push(m),
    onFramingError: (m) => framingErrors.push(m),
  });
  return { codec, messages, framingErrors };
}

describe("FrameCodec", () => {
  it("auto-detects newline mode on a bare JSON line", () => {
    const { codec, messages } = collect();
    codec.push(Buffer.from('{"jsonrpc":"2.0","method":"x"}\n', "utf8"));
    expect(codec.currentMode()).toBe("newline");
    expect(messages).toEqual([{ jsonrpc: "2.0", method: "x" }]);
  });

  it("auto-detects LSP mode on a Content-Length header", () => {
    const { codec, messages } = collect();
    const body = '{"jsonrpc":"2.0","method":"y"}';
    codec.push(
      Buffer.from(`Content-Length: ${body.length}\r\n\r\n${body}`, "utf8"),
    );
    expect(codec.currentMode()).toBe("lsp");
    expect(messages).toEqual([{ jsonrpc: "2.0", method: "y" }]);
  });

  it("waits for more bytes when only the 'C' prefix is buffered", () => {
    const { codec, messages } = collect();
    codec.push(Buffer.from("Conten", "utf8"));
    expect(codec.currentMode()).toBe("unknown");
    expect(messages).toEqual([]);
    const body = '{"jsonrpc":"2.0","method":"z"}';
    codec.push(
      Buffer.from(`t-Length: ${body.length}\r\n\r\n${body}`, "utf8"),
    );
    expect(codec.currentMode()).toBe("lsp");
    expect(messages).toEqual([{ jsonrpc: "2.0", method: "z" }]);
  });

  it("handles split chunks in newline mode", () => {
    const { codec, messages } = collect();
    codec.push(Buffer.from('{"jsonrpc":"2.0","m', "utf8"));
    codec.push(Buffer.from('ethod":"split"}\n', "utf8"));
    expect(messages).toEqual([{ jsonrpc: "2.0", method: "split" }]);
  });

  it("handles two LSP frames back-to-back in one chunk", () => {
    const { codec, messages } = collect();
    const a = '{"jsonrpc":"2.0","method":"a"}';
    const b = '{"jsonrpc":"2.0","method":"b"}';
    codec.push(
      Buffer.from(
        `Content-Length: ${a.length}\r\n\r\n${a}Content-Length: ${b.length}\r\n\r\n${b}`,
        "utf8",
      ),
    );
    expect(messages).toEqual([
      { jsonrpc: "2.0", method: "a" },
      { jsonrpc: "2.0", method: "b" },
    ]);
  });

  it("encodes outbound with LSP framing while the mode is unknown", () => {
    const { codec } = collect();
    const out = codec.encode({ jsonrpc: "2.0", method: "x" });
    expect(out.toString("utf8").startsWith("Content-Length:")).toBe(true);
  });

  it("encodes outbound as newline-delimited after detecting newline mode", () => {
    const { codec } = collect();
    codec.push(Buffer.from("{}\n", "utf8"));
    expect(codec.currentMode()).toBe("newline");
    const out = codec.encode({ jsonrpc: "2.0", method: "x" });
    expect(out.toString("utf8")).toBe('{"jsonrpc":"2.0","method":"x"}\n');
  });

  it("surfaces a framing error on a non-JSON body without breaking the channel", () => {
    const { codec, messages, framingErrors } = collect();
    codec.push(Buffer.from("not json\n", "utf8"));
    codec.push(Buffer.from('{"jsonrpc":"2.0","method":"after"}\n', "utf8"));
    expect(framingErrors.length).toBe(1);
    expect(messages).toEqual([{ jsonrpc: "2.0", method: "after" }]);
  });
});
