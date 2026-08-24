import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

/**
 * tmux-notify-jump extension for the omp (oh-my-pi) coding agent.
 *
 * omp has no shell-command hook system; its integration point is TypeScript
 * extensions. This extension is a thin bridge: it forwards omp lifecycle
 * events as JSON on stdin to notify-omp.sh, which handles all notification
 * logic (event filtering, remote-SSH suppression, tmux pane resolution,
 * focus-only fallback, UI/timeout routing).
 *
 * Install:
 *   Copy this file to ~/.omp/agent/extensions/tmux-notify-jump.ts
 *   (or <project>/.omp/extensions/ for per-project use)
 *   Ensure notify-omp.sh is on your PATH
 *
 * Environment variables (extension level; see notify-omp.sh for the rest):
 *   OMP_NOTIFY_CMD       bridge command (default: notify-omp.sh on PATH)
 *   OMP_NOTIFY_HEADLESS  also notify when omp runs without UI, i.e. print (-p)
 *                        and JSON event-stream modes (default: 0). TUI and
 *                        RPC (editor-driven) modes always notify: ctx.hasUI
 *                        is true there.
 *   OMP_NOTIFY_DEBUG     log extension diagnostics (default: 0)
 */

const FORWARDED_EVENTS = ["session_stop", "agent_end", "turn_end"] as const;

function isTruthy(value: string | undefined): boolean {
  if (!value) return false;
  return value === "1" || value === "true" || value === "yes" || value === "on";
}

function logDebug(msg: string): void {
  if (!isTruthy(process.env.OMP_NOTIFY_DEBUG)) return;
  try {
    const logfile =
      process.env.OMP_NOTIFY_DEBUG_LOG ||
      join(homedir(), ".omp", "agent", "logs", "notify-omp.log");
    mkdirSync(dirname(logfile), { recursive: true });
    appendFileSync(logfile, `${new Date().toISOString()} [extension] ${msg}\n`);
  } catch {
    // Never let debug logging break the extension
  }
}

function forward(eventName: string, ctx: ExtensionContext): void {
  try {
    if (!ctx.hasUI && !isTruthy(process.env.OMP_NOTIFY_HEADLESS)) {
      logDebug(`skipping ${eventName}: no UI (print/JSON mode; set OMP_NOTIFY_HEADLESS=1 to notify)`);
      return;
    }

    const cmd = process.env.OMP_NOTIFY_CMD || "notify-omp.sh";
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
    pi.on(eventName as "session_stop", async (_event, ctx) => {
      forward(eventName, ctx);
    });
  }
}
