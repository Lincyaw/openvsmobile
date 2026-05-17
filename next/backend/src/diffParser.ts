// Minimal unified-diff parser. We parse only the small subset git emits for
// a single file: optional `diff --git` / `index` / `---` / `+++` headers,
// then a sequence of `@@ -A,B +C,D @@` hunks each with ` `, `+`, `-`, or `\`
// lines. No multi-file streams, no rename headers special-casing — `git diff`
// is invoked one path at a time, so the parser only ever sees one file's
// patch.

export interface DiffHunk {
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  lines: DiffLine[];
}

export interface DiffLine {
  kind: "context" | "add" | "del" | "noNewline";
  text: string;
}

/// Parse a unified diff into structured hunks. Returns an empty array if the
/// input has no hunks (e.g. a header-only patch, which `git diff` emits when
/// only mode bits changed). Throws if a hunk header is malformed — we treat
/// that as a bug in either git or this parser, not as user-visible input.
export function parseUnifiedDiff(text: string): DiffHunk[] {
  const hunks: DiffHunk[] = [];
  // Splitting on \n keeps trailing empty entries; we filter at consumption.
  const lines = text.split("\n");
  let i = 0;
  // Skip preamble until the first hunk header.
  while (i < lines.length && !lines[i].startsWith("@@")) i++;

  while (i < lines.length) {
    const header = lines[i];
    if (!header.startsWith("@@")) break;
    const match = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(header);
    if (!match) {
      throw new Error(`malformed hunk header: ${header}`);
    }
    const oldStart = Number(match[1]);
    const oldLines = match[2] !== undefined ? Number(match[2]) : 1;
    const newStart = Number(match[3]);
    const newLines = match[4] !== undefined ? Number(match[4]) : 1;
    i++;
    const hunkLines: DiffLine[] = [];
    while (i < lines.length && !lines[i].startsWith("@@")) {
      const ln = lines[i];
      if (ln.length === 0 && i === lines.length - 1) {
        // Trailing newline from split — stop here.
        i++;
        break;
      }
      const prefix = ln.charAt(0);
      const rest = ln.slice(1);
      if (prefix === " ") {
        hunkLines.push({ kind: "context", text: rest });
      } else if (prefix === "+") {
        hunkLines.push({ kind: "add", text: rest });
      } else if (prefix === "-") {
        hunkLines.push({ kind: "del", text: rest });
      } else if (prefix === "\\") {
        // "\ No newline at end of file" marker. Attach to the previous line
        // semantically; preserve as its own entry so renderers can decide.
        hunkLines.push({ kind: "noNewline", text: rest });
      } else if (ln.length === 0) {
        // Blank line inside a hunk shouldn't happen in a well-formed unified
        // diff (every context line has a leading space) but we accept it as
        // a context line so a slightly off-spec emitter doesn't crash us.
        hunkLines.push({ kind: "context", text: "" });
      } else {
        // Any other prefix is the start of trailing junk; stop the hunk.
        break;
      }
      i++;
    }
    hunks.push({ oldStart, oldLines, newStart, newLines, lines: hunkLines });
  }
  return hunks;
}
