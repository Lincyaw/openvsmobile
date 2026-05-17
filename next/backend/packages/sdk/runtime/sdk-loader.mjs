// Side-effect-only loader: registers the SDK resolver hook on the main
// thread before the plugin's entry executes. The host invokes this file
// via `node --import file:///abs/path/to/sdk-loader.mjs index.js`.

import { register } from "node:module";

register("./sdk-resolver.mjs", import.meta.url);
