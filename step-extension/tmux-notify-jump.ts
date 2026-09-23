import type { ExtensionAPI, ExtensionContext } from "@step-harness/coding-agent";
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

/**
 * tmux-notify-jump extension for the Step Code CLI (`step`).
 *
 * Step Code has no shell-command hook system; its integration point is
 * TypeScript extensions. This extension is a thin bridge: it forwards Step
 * lifecycle events as JSON on stdin to notify-step.sh, which handles all
 * notification logic (event filtering, remote-SSH suppression, tmux pane
 * resolution, focus-only fallback, UI/timeout routing).
 *
 * Step Code keeps Pi's extension API, so `agent_settled`, `agent_end`, and
 * `turn_end` behave exactly as they do under `pi`.
 *
 * Install:
 *   Copy this file to ~/.stepcode/agent/extensions/tmux-notify-jump.ts
 *   Ensure notify-step.sh is on your PATH
 *
 * Environment variables (extension level; see notify-step.sh for the rest):
 *   STEP_NOTIFY_CMD       bridge command (default: notify-step.sh on PATH)
 *   STEP_NOTIFY_HEADLESS  also notify when step runs without UI, i.e. print
 *                         (-p) and JSON event-stream modes (default: 0). TUI
 *                         and RPC (editor-driven) modes always notify:
 *                         ctx.hasUI is true there.
 *   STEP_NOTIFY_DEBUG     log extension diagnostics (default: 0)
 *
 * `ui_prompt_start` is forwarded because step's own tool-approval prompt
 * ("Approve run_command [id]") is an extension dialog: the built-in
 * permission feature calls ctx.ui.confirm(), and the extension runner
 * broadcasts ui_prompt_start to every extension. The prompt title rides
 * along in the payload so the notification can name what step is waiting
 * for. The event only fires when a UI is available (TUI, RPC); print and
 * JSON modes fail closed instead of prompting. Note that it is a generic
 * "step is waiting for you" signal: any blocking extension dialog
 * (confirmation, input, selector) emits it, so enable it deliberately.
 */

const FORWARDED_EVENTS = ["agent_settled", "agent_end", "turn_end", "ui_prompt_start"] as const;

function isTruthy(value: string | undefined): boolean {
  if (!value) return false;
  return value === "1" || value === "true" || value === "yes" || value === "on";
}

function logDebug(msg: string): void {
  if (!isTruthy(process.env.STEP_NOTIFY_DEBUG)) return;
  try {
    const logfile =
      process.env.STEP_NOTIFY_DEBUG_LOG ||
      join(homedir(), ".stepcode", "agent", "logs", "notify-step.log");
    mkdirSync(dirname(logfile), { recursive: true });
    appendFileSync(logfile, `${new Date().toISOString()} [extension] ${msg}\n`);
  } catch {
    // Never let debug logging break the extension
  }
}

/** Read the prompt title from an event that carries one (ui_prompt_start). */
function extractTitle(event: unknown): string | undefined {
  if (typeof event !== "object" || event === null) return undefined;
  const title = (event as { title?: unknown }).title;
  return typeof title === "string" ? title : undefined;
}

function forward(eventName: string, ctx: ExtensionContext, title?: string): void {
  try {
    if (!ctx.hasUI && !isTruthy(process.env.STEP_NOTIFY_HEADLESS)) {
      logDebug(`skipping ${eventName}: no UI (print/JSON mode; set STEP_NOTIFY_HEADLESS=1 to notify)`);
      return;
    }

    const cmd = process.env.STEP_NOTIFY_CMD || "notify-step.sh";
    const payload = title === undefined ? JSON.stringify({ event: eventName }) : JSON.stringify({ event: eventName, title });
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
    pi.on(eventName as "agent_settled", async (event, ctx) => {
      forward(eventName, ctx, extractTitle(event));
    });
  }
}
