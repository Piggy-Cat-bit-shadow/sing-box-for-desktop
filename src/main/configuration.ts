/**
 * The shell's side of the daemon's configuration documents.
 *
 * The three RPCs live on the daemon's StartedService, which the packaged Windows client reaches
 * through the application worker relay (see `daemon.ts`), so the renderer cannot call them
 * directly: everything goes through this channel. That is also why this is a separate bridge from
 * the application service's `checkConfig`/`formatConfig` - those answer "is this document valid"
 * without a running Box, while these answer "what would applying it do" and "what did the last
 * apply do", which only a started service can know.
 *
 * The classification (document / absent / unsupported) is in `shared/configDocuments.ts`, where it
 * is tested without Electron. This module only supplies the calls and the IPC envelope.
 */

import { ipcMain } from "electron";

import {
  readConfigurationDocument,
  type ConfigRecoveryInfo,
  type ServiceChangePlan,
  type ServiceChangeReport,
} from "../shared/configDocuments";
import { CONFIGURATION_CALL, type ProfilesResult } from "../shared/ipc";
import { startedService } from "./daemon";

function requireStartedService(): NonNullable<typeof startedService> {
  if (startedService === null) {
    throw new Error("daemon is not available");
  }
  return startedService;
}

function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

const handlers: Record<string, (...callArguments: unknown[]) => Promise<unknown>> = {
  /**
   * What applying `configContent` would mean for the running instance.
   *
   * A rejected document is an RPC error from the daemon, not an empty plan: that path is left to
   * propagate so the editor can show the daemon's own message next to the document that caused it.
   */
  async previewChange(content: unknown): Promise<unknown> {
    if (typeof content !== "string") {
      throw new Error("config content must be a string");
    }
    const client = requireStartedService();
    return readConfigurationDocument<ServiceChangePlan>(
      async () => (await client.previewServiceChange({ configContent: content })).json,
    );
  },

  async lastServiceChange(): Promise<unknown> {
    const client = requireStartedService();
    return readConfigurationDocument<ServiceChangeReport>(
      async () => (await client.getLastServiceChange({})).json,
    );
  },

  async lastConfigRecovery(): Promise<unknown> {
    const client = requireStartedService();
    return readConfigurationDocument<ConfigRecoveryInfo>(
      async () => (await client.getLastConfigRecovery({})).json,
    );
  },
};

export function registerConfiguration(): void {
  ipcMain.handle(
    CONFIGURATION_CALL,
    async (
      _event,
      method: string,
      ...callArguments: unknown[]
    ): Promise<ProfilesResult> => {
      const handler = handlers[method];
      if (handler === undefined) {
        return { ok: false, error: `unknown configuration method: ${method}` };
      }
      try {
        return { ok: true, value: await handler(...callArguments) };
      } catch (error) {
        return { ok: false, error: describeError(error) };
      }
    },
  );
}
