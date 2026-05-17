// ESM resolver hook that maps the bare specifier `@openvsmobile/sdk`
// to this package's compiled entry point.
//
// Why this exists: Node's ESM `import` does not consult NODE_PATH (per
// the package resolution spec — bare specifiers walk `node_modules`
// only). A plugin staged under an arbitrary tempdir / user directory
// won't find the SDK without either filesystem manipulation or a
// resolver hook. Per design §3.4 ("plugins reference it via a
// host-injected resolver path") this is the host-injected path.
//
// The hook is registered by `sdk-loader.mjs` (run via `node --import`)
// before the plugin's own code executes, so the very first
// `import "@openvsmobile/sdk"` inside the plugin resolves cleanly.

import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, resolve as resolvePath } from "node:path";

const resolverDir = dirname(fileURLToPath(import.meta.url));
const SDK_URL = pathToFileURL(
  resolvePath(resolverDir, "..", "dist", "index.js"),
).href;

export async function resolve(specifier, context, nextResolve) {
  if (specifier === "@openvsmobile/sdk") {
    return { shortCircuit: true, url: SDK_URL, format: "module" };
  }
  return nextResolve(specifier, context);
}
