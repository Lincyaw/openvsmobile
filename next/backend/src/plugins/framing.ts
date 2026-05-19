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

/// Hard cap on a single inbound frame. A malformed or hostile plugin
/// could otherwise pin the host's heap by sending
/// `Content-Length: 9999999999\r\n\r\n` and never closing — the parser
/// would happily wait for 10 GiB of body. 16 MiB is the symmetric
/// default with `process.ts`'s stdin high-water mark; override via
/// `OPENVSMOBILE_PLUGIN_MAX_FRAME_BYTES` for tests / unusual cases.
function resolveMaxFrameSize(): number {
  const override = process.env.OPENVSMOBILE_PLUGIN_MAX_FRAME_BYTES;
  if (override !== undefined && override.length > 0) {
    const n = Number(override);
    if (Number.isFinite(n) && n > 0) return Math.floor(n);
  }
  return 16 * 1024 * 1024;
}
export const MAX_FRAME_SIZE = resolveMaxFrameSize();

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
  /// Chunk list, not a coalesced Buffer. `Buffer.concat` on every push
  /// is O(n²) over a sustained burst — keep chunks separate and only
  /// materialize a Buffer when we're about to inspect or slice. The
  /// `buf` accessor is lazy: it concats on demand and caches.
  private chunks: Buffer[] = [];
  private chunksBytes = 0;
  private coalesced: Buffer | null = null;
  private readonly sink: FrameSink;

  constructor(sink: FrameSink) {
    this.sink = sink;
  }

  private get buf(): Buffer {
    if (this.coalesced !== null) return this.coalesced;
    if (this.chunks.length === 0) {
      this.coalesced = Buffer.alloc(0);
      return this.coalesced;
    }
    if (this.chunks.length === 1) {
      this.coalesced = this.chunks[0] as Buffer;
      return this.coalesced;
    }
    this.coalesced = Buffer.concat(this.chunks, this.chunksBytes);
    // Replace the multi-chunk list with the single coalesced buffer so
    // we don't pay the concat cost again on the next access.
    this.chunks = [this.coalesced];
    return this.coalesced;
  }

  private set buf(b: Buffer) {
    this.chunks = b.length === 0 ? [] : [b];
    this.chunksBytes = b.length;
    this.coalesced = b;
  }

  /// Append bytes from the plugin's stdout. Drains everything we can
  /// parse out of the running buffer before returning.
  public push(chunk: Buffer): void {
    if (chunk.length === 0) return;
    this.chunks.push(chunk);
    this.chunksBytes += chunk.length;
    this.coalesced = null;
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
    if (!Number.isFinite(length) || length < 0 || length > MAX_FRAME_SIZE) {
      // Refuse the frame: discard the header bytes we've parsed so far
      // and reset to header-seeking. We do NOT consume bytes past the
      // header — we don't know where the body would end, and a hostile
      // length might be the precursor to a flood. The channel stays
      // open; subsequent valid frames recover.
      this.sink.onFramingError(
        `plugin frame Content-Length ${length} exceeds maximum ${MAX_FRAME_SIZE} (or is invalid)`,
      );
      this.buf = this.buf.subarray(headerEnd + 4);
      return true;
    }
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
