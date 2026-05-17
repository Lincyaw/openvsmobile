// Exits non-zero immediately. Used to verify the host marks the plugin
// `crashed` and does not attempt a restart.
process.stderr.write("crashy is about to exit(1)\n");
process.exit(1);
