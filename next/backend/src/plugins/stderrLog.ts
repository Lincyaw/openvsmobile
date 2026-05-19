// Rotating stderr sink for a plugin process. Cap is 5 MiB, one backup
// (.1). Rotation is checked lazily after writes — a single big burst can
// briefly exceed the cap until the next size sample triggers the roll.
//
// All filesystem work is async (createWriteStream + fs.stat) so a plugin
// emitting a stderr flood doesn't block the host's event loop. The
// public `write()` is synchronous from the caller's perspective — it
// returns immediately and the data is queued onto the underlying stream
// (with internal backpressure handling).

import { createWriteStream, existsSync, type WriteStream } from "node:fs";
import { mkdir, rename, stat, unlink } from "node:fs/promises";
import { dirname } from "node:path";

const MAX_BYTES = 5 * 1024 * 1024;
/// How many writes we let through before re-sampling the file size.
/// A larger window cuts the stat() cadence; a smaller one shortens the
/// window during which we can overrun the cap. 32 strikes a balance for
/// chatty plugins without leaving the cap meaningfully unenforced.
const ROTATION_SAMPLE_EVERY = 32;

export class StderrLog {
  private readonly path: string;
  private stream: WriteStream | null = null;
  /// Pending writes queued while the kernel pipe was full. Drained on
  /// the stream's `drain` event so a slow consumer doesn't block the
  /// host's event loop.
  private queued: Buffer[] = [];
  private paused = false;
  /// Approximate bytes written since the last rotation check.
  private writesSinceCheck = 0;
  /// True while a rotation is in flight; further writes queue.
  private rotating = false;

  constructor(path: string) {
    this.path = path;
  }

  public async open(): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });
    // Append, create if missing. 0600 so the file is private (it can
    // contain plugin-leaked tokens / paths the user wrote into source).
    this.stream = createWriteStream(this.path, { flags: "a", mode: 0o600 });
    this.stream.on("drain", () => {
      this.paused = false;
      this.flushQueue();
    });
    // Swallow late errors (file system unmount, disk full). Logging
    // about a log failure would loop; the plugin itself just loses
    // stderr visibility.
    this.stream.on("error", () => {});
  }

  public write(chunk: Buffer): void {
    if (this.stream === null) return;
    if (this.rotating || this.paused) {
      this.queued.push(chunk);
      return;
    }
    const ok = this.stream.write(chunk);
    if (!ok) this.paused = true;
    this.writesSinceCheck++;
    if (this.writesSinceCheck >= ROTATION_SAMPLE_EVERY) {
      this.writesSinceCheck = 0;
      void this.maybeRotate();
    }
  }

  public close(): void {
    if (this.stream === null) return;
    try {
      this.stream.end();
    } catch {
      // best-effort
    }
    this.stream = null;
  }

  /// Path the log is being written to. Used by tests.
  public filePath(): string {
    return this.path;
  }

  private flushQueue(): void {
    if (this.stream === null || this.rotating) return;
    while (this.queued.length > 0 && !this.paused) {
      const chunk = this.queued.shift() as Buffer;
      const ok = this.stream.write(chunk);
      if (!ok) this.paused = true;
    }
  }

  private async maybeRotate(): Promise<void> {
    if (this.rotating || this.stream === null) return;
    let size: number;
    try {
      const s = await stat(this.path);
      size = s.size;
    } catch {
      return;
    }
    if (size < MAX_BYTES) return;
    this.rotating = true;
    try {
      // Close current stream, then move the file aside and reopen.
      const oldStream = this.stream;
      this.stream = null;
      await new Promise<void>((resolve) => oldStream.end(() => resolve()));
      const backup = `${this.path}.1`;
      try {
        if (existsSync(backup)) {
          // No fancy multi-backup chain — keep one backup per issue spec.
          await unlink(backup).catch(() => {});
        }
        await rename(this.path, backup);
      } catch {
        // If rotation fails (e.g. concurrent write from another process)
        // the worst case is we keep appending past the cap. Reopen and
        // continue.
      }
      try {
        this.stream = createWriteStream(this.path, {
          flags: "a",
          mode: 0o600,
        });
        this.stream.on("drain", () => {
          this.paused = false;
          this.flushQueue();
        });
        this.stream.on("error", () => {});
      } catch {
        this.stream = null;
      }
    } finally {
      this.rotating = false;
      this.paused = false;
      this.flushQueue();
    }
  }
}
