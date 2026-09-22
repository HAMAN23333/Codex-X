import assert from "node:assert/strict";
import test from "node:test";
import { AppUpdaterController, isAppUpdateBusy, UPDATER_SLOW_NOTICE_MS } from "../src/appUpdaterController.ts";

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture() {
  const counts = { checks: 0, installs: 0, restarts: 0, closes: 0 };
  const timers = new Map();
  let timerId = 0;
  let update = { rid: 12, currentVersion: "0.3.20", version: "0.3.21", body: "Update notes", close: async () => { counts.closes++; } };
  let operation;
  let checkOperation;
  let restartOperation;
  const controller = new AppUpdaterController({
    check: async () => { counts.checks++; return checkOperation ? checkOperation.promise : update; },
    install: (value, onEvent, options) => {
      counts.installs++;
      operation = { ...deferred(), value, onEvent, options };
      return operation.promise;
    },
    restart: () => { counts.restarts++; return restartOperation?.promise || Promise.resolve(); },
    setTimer: (callback, delay) => { assert.equal(delay, UPDATER_SLOW_NOTICE_MS); timers.set(++timerId, callback); return timerId; },
    clearTimer: (id) => { timers.delete(id); },
  });
  return {
    controller, counts, timers,
    get operation() { return operation; },
    setCheckOperation(value) { checkOperation = value; },
    setRestartOperation(value) { restartOperation = value; },
    setUpdate(value) { update = value; },
    waitLonger() { for (const [id, callback] of timers) { timers.delete(id); callback(); } },
  };
}

test("download, verification and shutdown preparation are distinct; ready requires installation result", async () => {
  const f = fixture();
  assert.equal(await f.controller.check(), "available");
  const job = f.controller.downloadAndInstall({ timeout: 4000 });
  assert.equal(f.operation.options.timeout, 4000);
  f.operation.onEvent({ event: "Started", data: { contentLength: 100 } });
  f.operation.onEvent({ event: "Progress", data: { chunkLength: 100 } });
  assert.equal(f.controller.getSnapshot().phase, "downloading");
  for (const [event, phase] of [["Verifying", "verifying"], ["Preparing", "preparing"], ["Installing", "installing"]]) {
    f.operation.onEvent({ event });
    assert.equal(f.controller.getSnapshot().phase, phase);
    assert.equal(isAppUpdateBusy(phase), true);
  }
  f.operation.resolve({ restartRequired: true });
  assert.equal(await job, "ready");
  assert.equal(f.controller.getSnapshot().phase, "ready");
  assert.equal(f.timers.size, 0);
});

test("clicking repeatedly and checking during an update cannot launch a second installer", async () => {
  const f = fixture();
  await f.controller.check();
  const job = f.controller.downloadAndInstall();
  assert.equal(f.controller.downloadAndInstall(), job);
  assert.equal(f.controller.retry(), job);
  assert.equal(await f.controller.check({ force: true }), "available");
  assert.equal(f.counts.checks, 1);
  f.operation.onEvent({ event: "Preparing" });
  assert.equal(f.controller.downloadAndInstall(), job);
  f.operation.resolve({ restartRequired: true });
  await job;
  await f.controller.downloadAndInstall();
  await f.controller.check({ force: true });
  assert.equal(f.counts.installs, 1);
  assert.equal(f.counts.checks, 1);
  assert.equal(f.counts.closes, 0);
});

test("preparation failure is not success; shows safe details and allows a deliberate retry", async () => {
  const f = fixture();
  await f.controller.check();
  const job = f.controller.downloadAndInstall();
  f.operation.onEvent({ event: "Preparing" });
  f.operation.reject({ stage: "prepare", message: "无法恢复连接配置，尚未启动安装程序。", logPath: "C:\\Logs\\update.log" });
  assert.equal(await job, "error");
  assert.equal(f.controller.getSnapshot().failure, "prepare");
  assert.equal(f.controller.getSnapshot().errorMessage, "无法恢复连接配置，尚未启动安装程序。");
  assert.equal(f.controller.getSnapshot().logPath, "C:\\Logs\\update.log");
  assert.equal(f.timers.size, 0);
  const retry = f.controller.retry();
  assert.equal(f.counts.installs, 2);
  assert.equal(f.controller.getSnapshot().errorMessage, null);
  f.operation.resolve({ restartRequired: true });
  assert.equal(await retry, "ready");
});

test("signature rejection never displays success or exposes an arbitrary plugin error", async () => {
  const f = fixture();
  await f.controller.check();
  const job = f.controller.downloadAndInstall();
  f.operation.onEvent({ event: "Verifying" });
  f.operation.reject(new Error("signature failed at https://private.example.test?token=secret"));
  assert.equal(await job, "error");
  assert.equal(f.controller.getSnapshot().failure, "verify");
  assert.equal(f.controller.getSnapshot().errorMessage, null);
});

test("successful handoff followed by an IPC disconnect must not offer or start another installation", async () => {
  const f = fixture();
  await f.controller.check();
  const job = f.controller.downloadAndInstall();
  f.operation.onEvent({ event: "HandedOff" });
  f.operation.reject(new Error("IPC disconnected as the app exits"));
  assert.equal(await job, "handed-off");
  assert.equal(f.controller.getSnapshot().failure, null);
  assert.equal(isAppUpdateBusy(f.controller.getSnapshot().phase), true);
  assert.equal(await f.controller.retry(), "handed-off");
  assert.equal(await f.controller.restart(), "handed-off");
  f.waitLonger();
  assert.equal(f.controller.getSnapshot().takingLonger, true);
  assert.equal(f.counts.installs, 1);
  assert.equal(f.counts.restarts, 0);
});

test("handoff result without restart remains pending installer completion, not installed", async () => {
  const f = fixture();
  await f.controller.check();
  const job = f.controller.downloadAndInstall();
  f.operation.resolve({ restartRequired: false });
  assert.equal(await job, "handed-off");
  assert.equal(await f.controller.downloadAndInstall(), "handed-off");
  assert.equal(f.counts.installs, 1);
});

test("slow notices never abort a pending operation and new progress clears the notice", async () => {
  const f = fixture();
  await f.controller.check();
  const job = f.controller.downloadAndInstall();
  f.waitLonger();
  assert.equal(f.controller.getSnapshot().takingLonger, true);
  assert.equal(f.controller.getSnapshot().phase, "downloading");
  assert.equal(f.controller.retry(), job);
  f.operation.onEvent({ event: "Progress", data: { chunkLength: 12 } });
  assert.equal(f.controller.getSnapshot().takingLonger, false);
  f.operation.onEvent({ event: "Preparing" });
  f.waitLonger();
  assert.equal(f.controller.getSnapshot().takingLonger, true);
  assert.equal(f.controller.getSnapshot().phase, "preparing");
  assert.equal(f.counts.installs, 1);
  f.operation.resolve({ restartRequired: true });
  await job;
  assert.equal(f.controller.getSnapshot().takingLonger, false);
});

test("late events from a failed attempt do not corrupt the retried download", async () => {
  const f = fixture();
  await f.controller.check();
  const first = f.controller.downloadAndInstall();
  const old = f.operation;
  old.reject({ stage: "download", message: "Network unavailable" });
  await first;
  const second = f.controller.retry();
  old.onEvent({ event: "HandedOff" });
  old.onEvent({ event: "Progress", data: { chunkLength: 900 } });
  assert.equal(f.controller.getSnapshot().phase, "downloading");
  assert.equal(f.controller.getSnapshot().downloadedBytes, 0);
  f.operation.resolve({ restartRequired: true });
  await second;
});

test("only a confirmed ready update can relaunch, and failed relaunch retries only relaunch", async () => {
  const f = fixture();
  await f.controller.check();
  assert.equal(await f.controller.restart(), "available");
  const job = f.controller.downloadAndInstall();
  f.operation.resolve({ restartRequired: true });
  await job;
  const failed = deferred();
  f.setRestartOperation(failed);
  const restart = f.controller.restart();
  failed.reject(new Error("blocked"));
  assert.equal(await restart, "error");
  assert.equal(f.controller.getSnapshot().failure, "restart");
  f.setRestartOperation(null);
  assert.equal(await f.controller.retry(), "ready");
  assert.equal(f.controller.getSnapshot().phase, "ready");
  assert.equal(f.counts.restarts, 2);
  assert.equal(f.counts.installs, 1);
});

test("a pending forced check cannot install its stale update resource", async () => {
  const f = fixture();
  await f.controller.check();
  const next = deferred();
  f.setCheckOperation(next);
  const check = f.controller.check({ force: true });
  assert.equal(await f.controller.downloadAndInstall(), "checking");
  assert.equal(f.counts.installs, 0);
  next.resolve(null);
  await check;
  assert.equal(f.counts.closes, 1);
});
