import { chmod, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";

if (process.platform === "darwin") {
  const require = createRequire(import.meta.url);
  const packageJson = require.resolve("node-pty/package.json");
  const helper = join(
    dirname(packageJson),
    "prebuilds",
    `darwin-${process.arch}`,
    "spawn-helper",
  );

  const current = await stat(helper).catch((err) => {
    if (err?.code === "ENOENT") return null;
    throw err;
  });

  if (current !== null && (current.mode & 0o111) === 0) {
    await chmod(helper, current.mode | 0o755);
  }
}
