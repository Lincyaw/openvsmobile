import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Tests spawn `git` against real temp repos (conventions §6 — no FS / git
    // mocks). 20s per test handles slow CI; the median local run is sub-second.
    testTimeout: 20_000,
    hookTimeout: 20_000,
    // Real fs + watchers + git → can't run in parallel without flakes from
    // chokidar inotify limits + git's index.lock. Single-threaded is fine
    // for our test count.
    fileParallelism: false,
    include: [
      "test/**/*.test.ts",
      // The plugin SDK lives under `packages/sdk/` as a workspace
      // member; its unit tests run in the same vitest invocation so a
      // single `pnpm test` covers both halves of the plugin platform.
      "packages/*/test/**/*.test.ts",
    ],
    // ESM is the default in this project. Vitest picks it up from package.json
    // ("type": "module") — no extra config needed.
  },
});
