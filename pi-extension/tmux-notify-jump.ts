import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

/**
 * tmux-notify-jump extension for the Pi coding agent.
 *
 * Pi has no shell-command hook system; its integration point is TypeScript
 * extensions. This extension is a thin bridge: it forwards Pi lifecycle
 * events as JSON on stdin to notify-pi.sh, which handles all notification
 * logic (event filtering, remote-SSH suppression, tmux pane resolution,
 * focus-only fallback, UI/timeout routing).
 *
 * Install:
 *   Copy this file to ~/.pi/agent/extensions/tmux-notify-jump.ts
 *   Ensure notify-pi.sh is on your PATH
 *
 * Environment variables (extension level; see notify-pi.sh for the rest):
 *   PI_NOTIFY_CMD       bridge command (default: notify-pi.sh on PATH)
 *   PI_NOTIFY_HEADLESS  also notify when Pi runs without UI, i.e. print (-p)
 *                       and JSON event-stream modes (default: 0). TUI and
 *                       RPC (editor-driven) modes always notify: ctx.hasUI
 *                       is true there.
 *   PI_NOTIFY_DEBUG     log extension diagnostics (default: 0)
 */

const FORWARDED_EVENTS = ["agent_settled", "agent_end", "turn_end"] as const;

function isTruthy(value: string | undefined): boolean {
  if (!value) return false;
  return value === "1" || value === "true" || value === "yes" || value === "on";
}

function logDebug(msg: string): void {
  if (!isTruthy(process.env.PI_NOTIFY_DEBUG)) return;
  try {
    const logfile =
      process.env.PI_NOTIFY_DEBUG_LOG ||
      join(homedir(), ".pi", "agent", "logs", "notify-pi.log");
    mkdirSync(dirname(logfile), { recursive: true });
    appendFileSync(logfile, `${new Date().toISOString()} [extension] ${msg}\n`);
  } catch {
    // Never let debug logging break the extension
  }
}

function forward(eventName: string, ctx: ExtensionContext): void {
  try {
    if (!ctx.hasUI && !isTruthy(process.env.PI_NOTIFY_HEADLESS)) {
      logDebug(`skipping ${eventName}: no UI (print/JSON mode; set PI_NOTIFY_HEADLESS=1 to notify)`);
      return;
    }

    const cmd = process.env.PI_NOTIFY_CMD || "notify-pi.sh";
    const payload = JSON.stringify({ event: eventName });
    logDebug(`forwarding ${eventName} to ${cmd}`);

    const child = spawn(cmd, [], {
      detached: true,
      stdio: ["pipe", "ignore", "ignore"],
    });
    child.on("error", (err) => logDebug(`spawn error: ${err.message}`));
    child.stdin?.on("error", (err) => logDebug(`stdin error: ${err.message}`));
    child.stdin?.end(payload);
    child.unref();
  } catch (err) {
    logDebug(`forward failed: ${String(err)}`);
  }
}

export default function (pi: ExtensionAPI) {
  for (const eventName of FORWARDED_EVENTS) {
    pi.on(eventName as "agent_settled", async (_event, ctx) => {
      forward(eventName, ctx);
    });
  }
}
