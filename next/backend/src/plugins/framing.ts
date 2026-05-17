// stdio JSON-RPC framing for plugin processes.
//
// The issue asks the host to be tolerant of both framings used in
// practice:
//   * LSP-style Content-Length framing — what the design doc nominally
//     prescribes (§4.2) and what most LSP-aware stacks emit.
//   * Newline-delimited JSON — what a hello-world `console.log(JSON.stringify(...))`
//     plugin will emit. Common enough that requiring framing on the
//     plugin side would make trivial plugins painful.
//
// Strategy: buffer until we can decide. The first non-whitespace byte
// tells us — if it's `C` (start of `Content-Length:`) we treat the
// channel as LSP; anything else (typically `{`) → newline mode. The
// choice is sticky for the lifetime of the channel; we never re-detect
// mid-stream.
//
// Output framing follows the detected inbound mode. The plugin chose
// the mode on its first byte; we reply in kind so the plugin's parser
// doesn't need to be ambidextrous. Until we know, queued writes use
// LSP (the design doc's nominal mode); the queue is replayed in the
// chosen encoding the moment the mode flips.

const LSP_HEADER_HINT = "Content-Length";

type Mode = "lsp" | "newline" | "unknown";

export interface FrameSink {
  /// Called once per parsed JSON object. The handler can throw — caller
  /// catches and surfaces it.
  onMessage(obj: unknown): void;
  /// Called when a frame is structurally malformed (header without body,
  /// non-JSON payload, …). The channel stays open — same as JSON-RPC's
  /// own response semantics.
  onFramingError(message: string): void;
}

export class FrameCodec {
  private mode: Mode = "unknown";
  private buf: Buffer = Buffer.alloc(0);
  private readonly sink: FrameSink;

  constructor(sink: FrameSink) {
    this.sink = sink;
  }

  /// Append bytes from the plugin's stdout. Drains everything we can
  /// parse out of the running buffer before returning.
  public push(chunk: Buffer): void {
    this.buf = this.buf.length === 0 ? chunk : Buffer.concat([this.buf, chunk]);
    this.drain();
  }

  /// Encode `value` according to the channel's current mode. While the
  /// peer's mode is still unknown we default to LSP — the design doc's
  /// nominal wire shape.
  public encode(value: unknown): Buffer {
    const json = JSON.stringify(value);
    if (this.mode === "newline") {
      return Buffer.from(json + "\n", "utf8");
    }
    const body = Buffer.from(json, "utf8");
    const header = Buffer.from(
      `Content-Length: ${body.length}\r\n\r\n`,
      "utf8",
    );
    return Buffer.concat([header, body]);
  }

  /// Visible for tests so they can assert auto-detect outcomes.
  public currentMode(): Mode {
    return this.mode;
  }

  private drain(): void {
    while (true) {
      if (this.buf.length === 0) return;
      if (this.mode === "unknown") {
        const decided = this.tryDetect();
        if (!decided) return;
      }
      if (this.mode === "lsp") {
        if (!this.drainLsp()) return;
      } else if (this.mode === "newline") {
        if (!this.drainNewline()) return;
      }
    }
  }

  /// Inspect the head of the buffer to pick a mode. Returns `true` when
  /// a decision was made (mode flipped to "lsp" or "newline"), `false`
  /// when we need more bytes.
  private tryDetect(): boolean {
    // Skip ASCII whitespace at the head of the buffer until we hit a
    // payload byte we can read.
    let i = 0;
    while (i < this.buf.length) {
      const b = this.buf[i] as number;
      if (b !== 0x20 && b !== 0x09 && b !== 0x0a && b !== 0x0d) break;
      i++;
    }
    if (i > 0) this.buf = this.buf.subarray(i);
    if (this.buf.length === 0) return false;
    const first = this.buf[0] as number;
    if (first === 0x43 || first === 0x63) {
      // 'C' or 'c' — could be the start of `Content-Length:`. Wait for
      // enough bytes to confirm so we don't false-positive a JSON
      // string that happens to start with 'C'. (JSON literal payloads
      // start with `{`, `[`, `"`, a digit, `t`, `f`, or `n`; the only
      // legal newline-mode top-level value beginning with `C` is none —
      // JSON booleans / null are lowercase. So `C` is a strong LSP
      // signal even before we've read the full word.)
      if (this.buf.length < LSP_HEADER_HINT.length) return false;
      const sniff = this.buf
        .subarray(0, LSP_HEADER_HINT.length)
        .toString("ascii");
      if (sniff.toLowerCase() === LSP_HEADER_HINT.toLowerCase()) {
        this.mode = "lsp";
        return true;
      }
      this.mode = "newline";
      return true;
    }
    this.mode = "newline";
    return true;
  }

  /// Return `true` if a frame was emitted (caller loops); `false` if
  /// more bytes are needed.
  private drainLsp(): boolean {
    const headerEnd = this.buf.indexOf("\r\n\r\n");
    if (headerEnd === -1) return false;
    const header = this.buf.subarray(0, headerEnd).toString("ascii");
    const lengthMatch = /Content-Length:\s*(\d+)/i.exec(header);
    if (lengthMatch === null) {
      this.sink.onFramingError(
        `missing Content-Length in plugin frame header`,
      );
      this.buf = this.buf.subarray(headerEnd + 4);
      return true;
    }
    const length = Number(lengthMatch[1]);
    const bodyStart = headerEnd + 4;
    if (this.buf.length < bodyStart + length) return false;
    const body = this.buf.subarray(bodyStart, bodyStart + length);
    this.buf = this.buf.subarray(bodyStart + length);
    this.emitJson(body);
    return true;
  }

  private drainNewline(): boolean {
    const nl = this.buf.indexOf(0x0a);
    if (nl === -1) return false;
    const line = this.buf.subarray(0, nl);
    this.buf = this.buf.subarray(nl + 1);
    const trimmed =
      line.length > 0 && line[line.length - 1] === 0x0d
        ? line.subarray(0, line.length - 1)
        : line;
    if (trimmed.length === 0) return true;
    this.emitJson(trimmed);
    return true;
  }

  private emitJson(body: Buffer): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(body.toString("utf8"));
    } catch (err) {
      this.sink.onFramingError(
        `plugin frame body is not valid JSON: ${(err as Error).message}`,
      );
      return;
    }
    this.sink.onMessage(parsed);
  }
}
