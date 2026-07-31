import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * tmux-notify-jump extension for the Pi coding agent.
 *
 * Pi has no shell-command hook system; its integration point is TypeScript
 * extensions subscribing to lifecycle events. This extension bridges Pi
 * events to the tmux-notify-jump CLI, which handles the actual desktop
 * notification, tmux pane resolution, and click-to-jump behavior.
 *
 * Install:
 *   Copy this file to ~/.pi/agent/extensions/tmux-notify-jump.ts
 *   Ensure tmux-notify-jump is on your PATH
 *
 * Environment variables:
 *   PI_NOTIFY_CMD                 notify command (default: tmux-notify-jump)
 *   PI_NOTIFY_EVENTS              event whitelist, comma-separated, * = all
 *                                 (default: agent_settled)
 *   PI_NOTIFY_EXCLUDE_EVENTS      event blacklist (* disables everything)
 *   PI_NOTIFY_SHOW_EVENT_TYPE     include [event] in title (default: 1)
 *   PI_NOTIFY_TIMEOUT_MS          notification timeout (default: 0, sticky)
 *   PI_NOTIFY_UI                  notification|dialog (falls back to TMUX_NOTIFY_UI)
 *   PI_NOTIFY_FALLBACK_TARGET     outside tmux, target the most recently
 *                                 active tmux client pane (default: 0)
 *   PI_NOTIFY_FOCUS_ONLY_FALLBACK outside tmux, fall back to --focus-only
 *                                 (default: 1)
 *   PI_NOTIFY_DEBUG               log diagnostics (default: 0)
 */

const KNOWN_EVENTS = new Set(["agent_settled", "agent_end", "turn_end"]);

const TITLES: Record<string, string> = {
  agent_settled: "Response Complete",
  agent_end: "Agent Run Ended",
  turn_end: "Turn Ended",
};

function isTruthy(value: string | undefined): boolean {
  if (!value) return false;
  return value === "1" || value === "true" || value === "yes" || value === "on";
}

function isInteger(value: string): boolean {
  return /^\d+$/.test(value);
}

function isPaneId(value: string): boolean {
  return /^%\d+$/.test(value);
}

function isEventEnabled(
  name: string,
  whitelist: string,
  blacklist: string,
  defaults: string,
): boolean {
  const list = (s: string) =>
    s
      .split(",")
      .map((e) => e.trim())
      .filter((e) => e.length > 0);
  const exclude = list(blacklist);
  if (exclude.includes("*") || exclude.includes(name)) return false;
  const include = list(whitelist.length > 0 ? whitelist : defaults);
  return include.includes("*") || include.includes(name);
}

function logDebug(msg: string): void {
  if (!isTruthy(process.env.PI_NOTIFY_DEBUG)) return;
  try {
    const logfile =
      process.env.PI_NOTIFY_DEBUG_LOG ||
      join(homedir(), ".pi", "agent", "logs", "tmux-notify-jump.log");
    mkdirSync(join(logfile, ".."), { recursive: true });
    appendFileSync(
      logfile,
      `${new Date().toISOString()} ${msg}\n`,
    );
  } catch {
    // Never let debug logging break the extension
  }
}

/** Query tmux for a target pane; returns "" when unavailable. */
function tmuxQuery(args: string[]): string {
  try {
    const socket = process.env.TMUX_NOTIFY_TMUX_SOCKET;
    const fullArgs = socket ? ["-S", socket, ...args] : args;
    const res = spawnSync("tmux", fullArgs, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    if (res.status !== 0) return "";
    return (res.stdout || "").trim();
  } catch {
    return "";
  }
}

/** Most recently active tmux client pane (fallback target outside tmux). */
function bestClientPaneId(): string {
  const out = tmuxQuery([
    "list-clients",
    "-F",
    "#{client_activity} #{pane_id}",
  ]);
  let bestActivity = -1;
  let bestPane = "";
  for (const line of out.split("\n")) {
    const sp = line.indexOf(" ");
    if (sp <= 0) continue;
    const activity = Number(line.slice(0, sp));
    const pane = line.slice(sp + 1).trim();
    if (!Number.isInteger(activity) || !isPaneId(pane)) continue;
    if (activity > bestActivity) {
      bestActivity = activity;
      bestPane = pane;
    }
  }
  return bestPane;
}

function resolveTarget(): string {
  const tmuxPane = process.env.TMUX_PANE || "";
  if (isPaneId(tmuxPane)) return tmuxPane;

  if (process.env.TMUX) {
    const pane = tmuxQuery(["display-message", "-p", "#{pane_id}"]);
    if (isPaneId(pane)) return pane;
    const human = tmuxQuery(["display-message", "-p", "#S:#I.#P"]);
    if (human) return human;
  }

  const allowFallback =
    process.env.PI_NOTIFY_FALLBACK_TARGET ??
    process.env.TMUX_NOTIFY_FALLBACK_TARGET ??
    "0";
  if (isTruthy(allowFallback)) {
    const pane = bestClientPaneId();
    if (pane) return pane;
  }

  return "";
}

function notify(eventName: string): void {
  try {
    const events = process.env.PI_NOTIFY_EVENTS || "";
    const exclude = process.env.PI_NOTIFY_EXCLUDE_EVENTS || "";
    if (!isEventEnabled(eventName, events, exclude, "agent_settled")) {
      logDebug(`event not enabled: ${eventName}`);
      return;
    }

    const cmd = process.env.PI_NOTIFY_CMD || "tmux-notify-jump";
    const showType = process.env.PI_NOTIFY_SHOW_EVENT_TYPE ?? "1";
    const label = TITLES[eventName] || eventName;
    const title =
      showType !== "0" ? `Pi [${eventName}] ${label}` : `Pi ${label}`;

    const timeoutMs = process.env.PI_NOTIFY_TIMEOUT_MS || "0";
    if (!isInteger(timeoutMs)) {
      logDebug(`invalid PI_NOTIFY_TIMEOUT_MS: '${timeoutMs}'`);
      return;
    }

    const target = resolveTarget();
    const args: string[] = [];
    let body = "Click to jump to tmux pane";

    if (target) {
      args.push("--target", target);
    } else {
      const focusFallback =
        process.env.PI_NOTIFY_FOCUS_ONLY_FALLBACK ??
        process.env.TMUX_NOTIFY_FOCUS_ONLY_FALLBACK ??
        "1";
      if (!isTruthy(focusFallback)) {
        logDebug("no tmux target and focus-only fallback disabled");
        return;
      }
      body = "Click to focus terminal";
      args.push("--focus-only");
    }

    const ui = process.env.PI_NOTIFY_UI || process.env.TMUX_NOTIFY_UI || "";
    if (ui === "notification" || ui === "dialog") {
      args.push("--ui", ui);
    }

    args.push(
      "--title", title,
      "--body", body,
      "--detach",
      "--timeout", timeoutMs,
      "--sender-pid", String(process.pid),
    );
    if (!isTruthy(process.env.PI_NOTIFY_DEBUG)) {
      args.push("--quiet");
    }

    logDebug(`cmd=${cmd} event=${eventName} target=${target} args=${args.join(" ")}`);

    const child = spawn(cmd, args, {
      detached: true,
      stdio: "ignore",
    });
    child.on("error", (err) => logDebug(`spawn error: ${err.message}`));
    child.unref();
  } catch (err) {
    logDebug(`notify failed: ${String(err)}`);
  }
}

export default function (pi: ExtensionAPI) {
  for (const eventName of KNOWN_EVENTS) {
    pi.on(eventName as "agent_settled", async () => {
      notify(eventName);
    });
  }
}
