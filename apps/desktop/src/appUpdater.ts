import { useSyncExternalStore } from "react";
import { Channel, invoke } from "@tauri-apps/api/core";
import { check as checkForTauriUpdate } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { AppUpdaterController, type AppUpdateEvent } from "./appUpdaterController";

export { INITIAL_APP_UPDATER_STATE, isAppUpdateBusy } from "./appUpdaterController";
export type { AppUpdaterPhase, AppUpdaterState, AppUpdaterFailure, AppUpdaterCheckResult, AppUpdaterCheckOptions } from "./appUpdaterController";

export const appUpdater = new AppUpdaterController({
  check: checkForTauriUpdate,
  install: async (update, onEvent, options) => {
    const channel = new Channel<AppUpdateEvent>(onEvent);
    return invoke<{ restartRequired: boolean }>("install_app_update", {
      updateRid: update.rid,
      onEvent: channel,
      timeout: options?.timeout,
      headers: options?.headers ? Array.from(new Headers(options.headers).entries()) : undefined,
    });
  },
  restart: relaunch,
  setTimer: (callback, delay) => window.setTimeout(callback, delay),
  clearTimer: (timer) => window.clearTimeout(timer as number),
});

export function useAppUpdater() {
  const state = useSyncExternalStore(appUpdater.subscribe, appUpdater.getSnapshot, appUpdater.getSnapshot);
  return { state, check: appUpdater.check, downloadAndInstall: appUpdater.downloadAndInstall, retry: appUpdater.retry, restart: appUpdater.restart } as const;
}
