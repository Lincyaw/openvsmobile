// Notification-admin RPCs for agent completion hooks.

import type { MethodRegistry } from "../rpc.js";
import { getAgentHookStatus, installAgentHooks } from "../agentHooks.js";

export const METHOD_NOTIFICATION_INSTALL_AGENT_HOOKS =
  "notification.installAgentHooks";
export const METHOD_NOTIFICATION_AGENT_HOOK_STATUS =
  "notification.agentHookStatus";

export function register(methods: MethodRegistry): void {
  methods.set(METHOD_NOTIFICATION_AGENT_HOOK_STATUS, async () =>
    getAgentHookStatus(),
  );
  methods.set(METHOD_NOTIFICATION_INSTALL_AGENT_HOOKS, async () =>
    installAgentHooks(),
  );
}
