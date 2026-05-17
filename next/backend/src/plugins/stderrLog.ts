// Rotating stderr sink for a plugin process. Cap is 5 MiB, one backup
// (.1). Rotation is lazy on each `write()` — checked after append, so a
// single big burst can briefly exceed the cap until the next write rolls
// it. This matches what the issue asks for and keeps the write path
// allocation-free in the common case.

import {
  closeSync,
  existsSync,
  openSync,
  renameSync,
  statSync,
  writeSync,
} from "node:fs";
import { mkdir } from "node:fs/promises";
import { dirname } from "node:path";

const MAX_BYTES = 5 * 1024 * 1024;

export class StderrLog {
  private readonly path: string;
  private fd: number | null = null;

  constructor(path: string) {
    this.path = path;
  }

  public async open(): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });
    // Append, create if missing. 0600 so the file is private (it can
    // contain plugin-leaked tokens / paths the user wrote into source).
    this.fd = openSync(this.path, "a", 0o600);
  }

  public write(chunk: Buffer): void {
    if (this.fd === null) return;
    writeSync(this.fd, chunk);
    this.maybeRotate();
  }

  public close(): void {
    if (this.fd === null) return;
    try {
      closeSync(this.fd);
    } catch {
      // best-effort
    }
    this.fd = null;
  }

  /// Path the log is being written to. Used by tests.
  public filePath(): string {
    return this.path;
  }

  private maybeRotate(): void {
    if (this.fd === null) return;
    let size: number;
    try {
      size = statSync(this.path).size;
    } catch {
      return;
    }
    if (size < MAX_BYTES) return;
    // Close current fd, rotate, reopen.
    try {
      closeSync(this.fd);
    } catch {
      // best-effort
    }
    this.fd = null;
    const backup = `${this.path}.1`;
    try {
      if (existsSync(backup)) {
        // No fancy multi-backup chain — keep one backup per issue spec.
        try {
          renameSync(backup, `${backup}.tmp`);
        } catch {
          // best-effort
        }
      }
      renameSync(this.path, backup);
    } catch {
      // If rotation fails (e.g. concurrent write from another process)
      // the worst case is we keep appending past the cap. Reopen and
      // continue.
    }
    try {
      this.fd = openSync(this.path, "a", 0o600);
    } catch {
      this.fd = null;
    }
  }
}
