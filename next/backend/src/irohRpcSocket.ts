// Shared newline-delimited JSON-RPC framing for Iroh clients and server.
import { EventEmitter } from "node:events";
import { StringDecoder } from "node:string_decoder";
const DEFAULT_FRAME_LIMIT = 1024 * 1024;
type ByteArray = number[];
export interface IrohConnection {
  acceptBi(): Promise<IrohBiStream>;
  remoteId(): { toString(): string };
  close(errorCode: bigint, reason: ByteArray): void;
  closed(): Promise<string>;
}

export interface IrohBiStream {
  send: IrohSendStream;
  recv: IrohRecvStream;
}

interface IrohSendStream {
  writeAll(buf: ByteArray): Promise<void>;
  finish(): Promise<void>;
  reset(errorCode: bigint): Promise<void>;
}

interface IrohRecvStream {
  read(sizeLimit: number): Promise<ByteArray>;
}

export class IrohRpcSocket extends EventEmitter {
  public readonly OPEN = 1;
  public readonly CLOSING = 2;
  public readonly CLOSED = 3;
  public readyState = this.OPEN;
  public bufferedAmount = 0;
  private pending = "";
  private readonly decoder = new StringDecoder("utf8");
  private writeChain: Promise<void> = Promise.resolve();
  private readonly maxFrameBytes: number;

  constructor(
    private readonly stream: IrohBiStream,
    private readonly conn: IrohConnection,
    maxFrameBytes?: number,
  ) {
    super();
    this.maxFrameBytes =
      maxFrameBytes ??
      parsePositiveInt(
        process.env.OPENVSMOBILE_IROH_MAX_FRAME_BYTES,
        DEFAULT_FRAME_LIMIT,
      );
  }

  public start(): void {
    void this.readLoop();
    void this.conn.closed().then(
      () => this.finishClose(),
      () => this.finishClose(),
    );
  }

  public send(msg: string, cb?: (err?: Error) => void): void {
    if (this.readyState !== this.OPEN) {
      cb?.(new Error("Iroh stream is closed"));
      return;
    }
    const payload = Buffer.from(`${msg}\n`, "utf8");
    this.bufferedAmount += payload.length;
    this.writeChain = this.writeChain
      .then(async () => {
        await this.stream.send.writeAll(Array.from(payload));
      })
      .then(
        () => cb?.(),
        (err: unknown) => {
          const error = err instanceof Error ? err : new Error(String(err));
          cb?.(error);
          this.emit("error", error);
          this.finishClose();
        },
      )
      .finally(() => {
        this.bufferedAmount = Math.max(0, this.bufferedAmount - payload.length);
      });
  }

  public close(code = 0, reason = ""): void {
    if (this.readyState !== this.OPEN) return;
    this.readyState = this.CLOSING;
    this.writeChain
      .then(() => this.stream.send.finish())
      .catch(() => {})
      .finally(() => {
        try {
          this.conn.close(BigInt(code), bytes(String(reason).slice(0, 256)));
        } catch {
          // Already closed.
        }
        this.finishClose();
      });
  }

  public terminate(): void {
    if (this.readyState === this.CLOSED) return;
    this.readyState = this.CLOSING;
    try {
      this.stream.send.reset(1n).catch(() => {});
    } catch {
      // Already gone.
    }
    try {
      this.conn.close(1n, bytes("terminated"));
    } catch {
      // Already gone.
    }
    this.finishClose();
  }

  private async readLoop(): Promise<void> {
    try {
      while (this.readyState === this.OPEN) {
        const chunk = await this.stream.recv.read(16 * 1024);
        if (chunk.length === 0) break;
        this.acceptBytes(this.decoder.write(Buffer.from(chunk)));
      }
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      this.emit("error", error);
    } finally {
      this.finishClose();
    }
  }

  private acceptBytes(text: string): void {
    this.pending += text;
    for (;;) {
      const idx = this.pending.indexOf("\n");
      const frame = idx < 0 ? this.pending : this.pending.slice(0, idx);
      if (Buffer.byteLength(frame, "utf8") > this.maxFrameBytes) {
        this.emit("error", new Error("Iroh JSON-RPC frame too large"));
        this.terminate();
        return;
      }
      if (idx < 0) return;
      const message = frame.trimEnd();
      this.pending = this.pending.slice(idx + 1);
      if (message.length > 0) {
        this.emit("message", message);
      }
    }
  }

  private finishClose(): void {
    if (this.readyState === this.CLOSED) return;
    this.readyState = this.CLOSED;
    this.emit("close");
  }
}

function bytes(s: string): ByteArray {
  return Array.from(Buffer.from(s, "utf8"));
}

function parsePositiveInt(raw: string | undefined, fallback: number): number {
  if (raw === undefined || raw.length === 0) return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) return fallback;
  return n;
}
