// Single source of truth for the backend version string.
//
// `package.json`'s `version` field is the canonical value. We read it once at
// boot and pass it through to every consumer (runtime.json, handshake reply).
// Hard-coding the version anywhere else is a convention violation — see
// docs/conventions.md §1 "Never duplicate the version string".

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/// Read the version field from this package's `package.json`. Works under
/// both `tsx src/index.ts` (cwd may be anywhere) and compiled
/// `node dist/index.js` (running from the install dir): in both cases the
/// file sits one directory above the source/build dir.
export function readPackageVersion(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  // dist/version.js → ../package.json; src/version.ts → ../package.json.
  const pkgPath = join(here, "..", "package.json");
  const raw = readFileSync(pkgPath, "utf8");
  const parsed = JSON.parse(raw) as { version?: unknown };
  if (typeof parsed.version !== "string" || parsed.version.length === 0) {
    throw new Error(`package.json missing string "version" field`);
  }
  return parsed.version;
}
