# AgentM Gateway

Mobile-native AgentM gateway peer. The plugin connects to an AgentM gateway,
renders a compact native panel, forwards in-app messages as AgentM
`inbound` envelopes, and turns final AgentM replies into replyable
openvsmobile notifications.

The panel is intentionally not a traditional chat UI. Its first focus stops
are status, last visible AgentM reply, message input, Send message, Stop
current turn, and Read last reply. Recent activity is capped to the latest few
events, while socket/cwd diagnostics stay behind Show details.

Configuration is via plugin-safe environment variables. The plugin host only
passes `OPENVSMOBILE_PLUGIN_*` variables through to plugin processes.

| Env var | Default |
|---------|---------|
| `OPENVSMOBILE_PLUGIN_AGENTM_CONNECT` | `unix://$XDG_RUNTIME_DIR/agentm-gw.sock`, or `unix:///tmp/agentm-gw-<uid>.sock` |
| `OPENVSMOBILE_PLUGIN_AGENTM_TOKEN` | unset |
| `OPENVSMOBILE_PLUGIN_AGENTM_CWD` | active openvsmobile workspace root, else plugin cwd |
| `OPENVSMOBILE_PLUGIN_AGENTM_CHANNEL` | `openvsmobile` |
| `OPENVSMOBILE_PLUGIN_AGENTM_CHAT_ID` | `phone` |
| `OPENVSMOBILE_PLUGIN_AGENTM_SESSION_KEY` | `<channel>:<chat_id>` |
| `OPENVSMOBILE_PLUGIN_AGENTM_SENDER_ID` | `openvsmobile` |
| `OPENVSMOBILE_PLUGIN_AGENTM_SENDER_NAME` | `OpenVS Mobile` |
| `OPENVSMOBILE_PLUGIN_AGENTM_SCENARIO` | unset |

Supported transports are `unix://`, `ws://`, and `wss://`. WebSocket support
uses the Node runtime's built-in `WebSocket`; Unix sockets use `node:net`.
