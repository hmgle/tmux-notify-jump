#!/usr/bin/env bash
set -euo pipefail

MODE="symlink" # symlink|copy
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="${BINDIR:-}"
UNINSTALL=0
CONFIGURE_CODEX=0
CONFIGURE_CLAUDE=0
CONFIGURE_KIMI=0
CONFIGURE_GROK=0
CONFIGURE_OPENCODE=0
CONFIGURE_PI=0
CONFIGURE_TMUX=0
CODEX_CONFIG_PATH="${CODEX_CONFIG_PATH:-}"
CLAUDE_CONFIG_PATH="${CLAUDE_CONFIG_PATH:-}"
KIMI_CONFIG_PATH="${KIMI_CONFIG_PATH:-}"
GROK_HOOKS_PATH="${GROK_HOOKS_PATH:-}"
OPENCODE_PLUGIN_PATH="${OPENCODE_PLUGIN_PATH:-}"
PI_EXTENSION_PATH="${PI_EXTENSION_PATH:-}"
TMUX_CONFIG_PATH="${TMUX_CONFIG_PATH:-$HOME/.tmux.conf}"
TMUX_KEY="${TMUX_KEY:-N}"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --prefix <dir>    Install prefix (default: \$HOME/.local)
  --bindir <dir>    Install directory for scripts (default: <prefix>/bin)
  --symlink         Install via symlinks (default)
  --copy            Install via copies
  --configure-codex Configure Codex notify hook (opt-in)
  --configure-claude Configure Claude hooks (opt-in)
  --configure-kimi  Configure Kimi Code CLI hooks (opt-in)
  --configure-grok  Configure Grok Build hooks (opt-in)
  --configure-opencode Configure OpenCode plugin (opt-in)
  --configure-pi    Configure Pi coding agent extension (opt-in)
  --configure-tmux  Configure tmux status, hooks, and prefix key (opt-in)
  --codex-config <path>  Codex config.toml path (default: ~/.codex/config.toml)
  --claude-config <path> Claude settings.json path (default: ~/.claude/settings.json)
  --kimi-config <path>   Kimi config.toml path (default: ~/.kimi-code/config.toml)
  --grok-hooks-path <path> Grok hooks dir (default: \$GROK_HOME/hooks or ~/.grok/hooks)
  --opencode-plugin-path <path> OpenCode plugins dir (default: ~/.config/opencode/plugins)
  --pi-extension-path <path> Pi extensions dir (default: ~/.pi/agent/extensions)
  --tmux-config <path> tmux config path (default: ~/.tmux.conf)
  --tmux-key <key>  Prefix key for Inbox next (default: N)
  --uninstall       Remove installed files
  -h, --help        Show help

Examples:
  $0 --prefix "\$HOME/.local" --symlink
  $0 --bindir "\$HOME/bin" --copy
  $0 --prefix "\$HOME/.local" --symlink --configure-codex
  $0 --prefix "\$HOME/.local" --symlink --configure-claude
  $0 --prefix "\$HOME/.local" --symlink --configure-kimi
  $0 --prefix "\$HOME/.local" --symlink --configure-grok
  $0 --prefix "\$HOME/.local" --symlink --configure-opencode
  $0 --prefix "\$HOME/.local" --symlink --configure-pi
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

timestamp() {
    date +"%Y%m%d%H%M%S" 2>/dev/null || date
}

backup_file() {
    local path="$1"
    [ -f "$path" ] || return 0
    local ts
    ts="$(timestamp)"
    cp -p "$path" "$path.bak.$ts"
}

file_mode() {
    local path="$1" mode=""
    mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
    if [ -z "$mode" ]; then
        mode="$(stat -f '%Lp' "$path" 2>/dev/null || true)"
    fi
    printf '%s' "$mode"
}

write_tmux_config_block() {
    local notify_cmd="$1" key="$2" shell_cmd=""
    printf -v shell_cmd '%q --tmux-init' "$notify_cmd"
    shell_cmd="${shell_cmd//\\/\\\\}"
    shell_cmd="${shell_cmd//\"/\\\"}"
    shell_cmd="${shell_cmd//\$/\\$}"
    shell_cmd="${shell_cmd//\`/\\\`}"
    printf '%s\n' '# BEGIN tmux-notify-jump'
    printf 'set -g @tmux-notify-jump-key %s\n' "$key"
    printf 'run-shell -b "%s"\n' "$shell_cmd"
    printf '%s\n' '# END tmux-notify-jump'
}

configure_tmux() {
    local notify_cmd="$1"
    local cfg="$TMUX_CONFIG_PATH"
    ensure_parent_dir "$cfg"
    if [ -f "$cfg" ]; then
        backup_file "$cfg"
    fi
    local tmp="" mode="" found=0 skip=0 line=""
    tmp="$(mktemp "${cfg}.tmp.XXXXXX")"
    if [ -f "$cfg" ]; then
        mode="$(file_mode "$cfg")"
        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$line" = "# BEGIN tmux-notify-jump" ]; then
                if [ "$found" -eq 0 ]; then
                    write_tmux_config_block "$notify_cmd" "$TMUX_KEY" >>"$tmp"
                    found=1
                fi
                skip=1
                continue
            fi
            if [ "$line" = "# END tmux-notify-jump" ] && [ "$skip" -eq 1 ]; then
                skip=0
                continue
            fi
            [ "$skip" -eq 1 ] || printf '%s\n' "$line" >>"$tmp"
        done <"$cfg"
    fi
    if [ "$found" -eq 0 ]; then
        write_tmux_config_block "$notify_cmd" "$TMUX_KEY" >>"$tmp"
    fi
    [ -z "$mode" ] || chmod "$mode" "$tmp"
    mv -f "$tmp" "$cfg"
    echo "Configured tmux: $cfg (prefix+$TMUX_KEY)"
}

unconfigure_tmux() {
    local cfg="$TMUX_CONFIG_PATH"
    [ -f "$cfg" ] || return 0
    backup_file "$cfg"
    local tmp="" mode="" skip=0 line=""
    tmp="$(mktemp "${cfg}.tmp.XXXXXX")"
    mode="$(file_mode "$cfg")"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "# BEGIN tmux-notify-jump" ]; then
            skip=1
            continue
        fi
        if [ "$line" = "# END tmux-notify-jump" ] && [ "$skip" -eq 1 ]; then
            skip=0
            continue
        fi
        [ "$skip" -eq 1 ] || printf '%s\n' "$line" >>"$tmp"
    done <"$cfg"
    [ -z "$mode" ] || chmod "$mode" "$tmp"
    mv -f "$tmp" "$cfg"
    echo "Removed tmux configuration: $cfg"
}

ensure_parent_dir() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
}

configure_codex() {
    local notify_cmd="$1"
    local cfg="${CODEX_CONFIG_PATH:-$HOME/.codex/config.toml}"

    ensure_parent_dir "$cfg"

    toml_root_has_notify_key() {
        local path="$1"
        awk '
            BEGIN { in_root = 1 }
            {
                line = $0
                sub(/^[ \t]+/, "", line)
                if (line ~ /^#/) next
                sub(/[ \t]*#.*/, "", line)
                if (line ~ /^\[\[?[^]]+\]\]?/) { in_root = 0 }
                if (in_root && line ~ /^notify[ \t]*=/) { found = 1; exit }
            }
            END { exit(found ? 0 : 1) }
        ' "$path" >/dev/null 2>&1
    }

    toml_root_has_string() {
        local path="$1"
        local needle="$2"
        awk -v needle="$needle" '
            BEGIN { in_root = 1 }
            {
                line = $0
                sub(/^[ \t]+/, "", line)
                if (line ~ /^#/) next
                sub(/[ \t]*#.*/, "", line)
                if (line ~ /^\[\[?[^]]+\]\]?/) { in_root = 0 }
                if (in_root && index(line, needle) > 0) { found = 1; exit }
            }
            END { exit(found ? 0 : 1) }
        ' "$path" >/dev/null 2>&1
    }

    toml_any_has_notify_key() {
        local path="$1"
        awk '
            {
                line = $0
                sub(/^[ \t]+/, "", line)
                if (line ~ /^#/) next
                sub(/[ \t]*#.*/, "", line)
                if (line ~ /^notify[ \t]*=/) { found = 1; exit }
            }
            END { exit(found ? 0 : 1) }
        ' "$path" >/dev/null 2>&1
    }

    insert_root_notify_block() {
        local path="$1"
        local cmd="$2"
        local tmp
        tmp="$(mktemp)"
        awk -v cmd="$cmd" '
            function print_block(at_top) {
                if (!at_top) print ""
                print "# Added by tmux-notify-jump install.sh"
                printf("notify = [\"%s\"]\n", cmd)
                print ""
            }
            BEGIN { inserted = 0 }
            {
                if (!inserted && $0 ~ /^[ \t]*\[\[?[^]]+\]\]?[ \t]*(#.*)?$/) {
                    print_block(NR == 1)
                    inserted = 1
                }
                print $0
            }
            END {
                if (!inserted) print_block(NR == 0)
            }
        ' "$path" >"$tmp"
        mv -f "$tmp" "$path"
    }

    if [ -f "$cfg" ]; then
        if toml_root_has_string "$cfg" "notify-codex.sh"; then
            echo "Codex already configured: $cfg"
            return 0
        fi
        if toml_root_has_notify_key "$cfg"; then
            echo "Codex config already has a top-level notify=; not modifying: $cfg"
            echo "Set it manually to include: $notify_cmd"
            return 0
        fi
        backup_file "$cfg"
        if toml_any_has_notify_key "$cfg"; then
            echo "Note: $cfg already contains notify= under a table; adding top-level notify= anyway."
        fi
        insert_root_notify_block "$cfg" "$notify_cmd"
        echo "Configured Codex notify hook in: $cfg"
        return 0
    fi

    backup_file "$cfg"
    {
        echo "# Codex config (generated by tmux-notify-jump install.sh)"
        printf 'notify = ["%s"]\n' "$notify_cmd"
    } >"$cfg"
    echo "Created Codex config with notify hook: $cfg"
}

configure_claude() {
    local notify_cmd="$1"
    local cfg="${CLAUDE_CONFIG_PATH:-$HOME/.claude/settings.json}"

    ensure_parent_dir "$cfg"

    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 not found; cannot auto-configure Claude settings. Edit manually:"
        echo "  ~/.claude/settings.json -> hooks Stop/Notification -> command: $notify_cmd"
        return 0
    fi

    if [ -f "$cfg" ]; then
        backup_file "$cfg"
    fi

    python3 - "$cfg" "$notify_cmd" <<'PY'
import json
import os
import sys

path = sys.argv[1]
cmd = sys.argv[2]

def load():
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as f:
        s = f.read().strip()
        if not s:
            return {}
        return json.loads(s)

def ensure_obj(x):
    return x if isinstance(x, dict) else {}

def ensure_list(x):
    return x if isinstance(x, list) else []

data = ensure_obj(load())
hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    # Don't clobber unknown schema
    print(f"Claude settings has non-object hooks; not modifying: {path}")
    sys.exit(0)

def has_command(event_name):
    ev = hooks.get(event_name)
    if not isinstance(ev, list):
        return False
    for entry in ev:
        if not isinstance(entry, dict):
            continue
        hook_list = entry.get("hooks")
        if not isinstance(hook_list, list):
            continue
        for h in hook_list:
            if not isinstance(h, dict):
                continue
            if h.get("type") != "command":
                continue
            existing = h.get("command")
            if existing == cmd:
                return True
    return False

if not has_command("Stop"):
    stop_list = hooks.get("Stop")
    if stop_list is None:
        hooks["Stop"] = []
        stop_list = hooks["Stop"]
    if not isinstance(stop_list, list):
        print(f"Claude hooks.Stop is not a list; not modifying: {path}")
        sys.exit(0)
    stop_list.append({"hooks": [{"type": "command", "command": cmd}]})

if not has_command("Notification"):
    notif_list = hooks.get("Notification")
    if notif_list is None:
        hooks["Notification"] = []
        notif_list = hooks["Notification"]
    if not isinstance(notif_list, list):
        print(f"Claude hooks.Notification is not a list; not modifying: {path}")
        sys.exit(0)
    notif_list.append(
        {
            "matcher": "permission_prompt|idle_prompt",
            "hooks": [{"type": "command", "command": cmd}],
        }
    )

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(f"Configured Claude hooks in: {path}")
PY
}

configure_kimi() {
    local notify_cmd="$1"
    local cfg="${KIMI_CONFIG_PATH:-$HOME/.kimi-code/config.toml}"
    local escaped_cmd=""
    local cfg_empty=0

    ensure_parent_dir "$cfg"

    if [ -f "$cfg" ] && grep -F 'notify-kimi-code.sh' "$cfg" >/dev/null 2>&1; then
        echo "Kimi Code CLI already configured: $cfg"
        return 0
    fi

    if [ -f "$cfg" ] && awk '
        BEGIN { in_root = 1 }
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            if (line ~ /^#/) next
            sub(/[ \t]*#.*/, "", line)
            if (line ~ /^\[\[?[^]]+\]\]?/) { in_root = 0 }
            if (in_root && line ~ /^hooks[ \t]*=/) { found = 1; exit }
        }
        END { exit(found ? 0 : 1) }
    ' "$cfg" >/dev/null 2>&1; then
        echo "Kimi config already has a top-level hooks= value; not modifying: $cfg"
        echo "Add Stop, PermissionRequest, StopFailure, and Notification hooks manually."
        echo "Hook command: $notify_cmd"
        return 0
    fi

    if [ -f "$cfg" ]; then
        backup_file "$cfg"
    fi

    escaped_cmd="${notify_cmd//\/\\}"
    escaped_cmd="${escaped_cmd//\"/\\\"}"
    [ -s "$cfg" ] || cfg_empty=1

    {
        if [ "$cfg_empty" -eq 1 ]; then
            echo "# Kimi Code CLI config (generated by tmux-notify-jump install.sh)"
        else
            echo ""
        fi
        echo "# Added by tmux-notify-jump install.sh"
        echo "[[hooks]]"
        echo 'event = "Stop"'
        printf 'command = "%s"\n' "$escaped_cmd"
        echo ""
        echo "[[hooks]]"
        echo 'event = "PermissionRequest"'
        printf 'command = "%s"\n' "$escaped_cmd"
        echo ""
        echo "[[hooks]]"
        echo 'event = "StopFailure"'
        printf 'command = "%s"\n' "$escaped_cmd"
        echo ""
        echo "[[hooks]]"
        echo 'event = "Notification"'
        printf 'command = "%s"\n' "$escaped_cmd"
    } >>"$cfg"

    echo "Configured Kimi Code CLI hooks in: $cfg"
}

configure_grok() {
    local notify_cmd="$1"
    local grok_home="${GROK_HOME:-$HOME/.grok}"
    local hooks_dir="${GROK_HOOKS_PATH:-$grok_home/hooks}"
    local cfg="$hooks_dir/tmux-notify-jump.json"

    mkdir -p "$hooks_dir"

    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 not found; cannot auto-configure Grok Build hooks. Edit manually:"
        echo "  $cfg -> hooks Stop/Notification/PostToolUseFailure -> command: $notify_cmd"
        return 0
    fi

    python3 - "$cfg" "$notify_cmd" <<'PY'
import json
import os
import shutil
import sys
import time

path = sys.argv[1]
cmd = sys.argv[2]

if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            content = handle.read().strip()
            data = json.loads(content) if content else {}
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Grok hook config is not valid JSON; not modifying: {path} ({exc})")
        sys.exit(0)
else:
    data = {}

if not isinstance(data, dict):
    print(f"Grok hook config root is not an object; not modifying: {path}")
    sys.exit(0)

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print(f"Grok hook config has non-object hooks; not modifying: {path}")
    sys.exit(0)

def has_handler(event_name):
    event_hooks = hooks.get(event_name)
    if not isinstance(event_hooks, list):
        return False
    for entry in event_hooks:
        if not isinstance(entry, dict):
            continue
        handlers = entry.get("hooks")
        if not isinstance(handlers, list):
            continue
        for handler in handlers:
            if not isinstance(handler, dict):
                continue
            if handler.get("type") == "command" and handler.get("command") == cmd:
                return True
    return False

def add_handler(event_name, matcher=None):
    event_hooks = hooks.setdefault(event_name, [])
    if not isinstance(event_hooks, list):
        raise TypeError(f"hooks.{event_name} is not a list")

    entry = {"hooks": [{"type": "command", "command": cmd}]}
    if matcher is not None:
        entry["matcher"] = matcher
    event_hooks.append(entry)

required = [
    ("Stop", None),
    ("Notification", "permission_prompt|idle_prompt"),
    ("PostToolUseFailure", None),
]

try:
    missing = []
    for event_name, matcher in required:
        event_hooks = hooks.get(event_name)
        if event_hooks is not None and not isinstance(event_hooks, list):
            raise TypeError(f"hooks.{event_name} is not a list")
        if not has_handler(event_name):
            missing.append((event_name, matcher))
except TypeError as exc:
    print(f"Grok hook config has an incompatible schema; not modifying: {path} ({exc})")
    sys.exit(0)

if not missing:
    print(f"Grok Build already configured: {path}")
    sys.exit(0)

if os.path.exists(path):
    shutil.copy2(path, f"{path}.bak.{time.strftime('%Y%m%d%H%M%S')}")

for event_name, matcher in missing:
    add_handler(event_name, matcher)

with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")

print(f"Configured Grok Build hooks in: {path}")
PY
}

configure_opencode() {
    local plugin_dir="${OPENCODE_PLUGIN_PATH:-$HOME/.config/opencode/plugins}"
    local plugin_src="$REPO_DIR/opencode-plugin/tmux-notify-jump.ts"
    local plugin_dst="$plugin_dir/tmux-notify-jump.ts"

    if [ ! -f "$plugin_src" ]; then
        echo "Warning: plugin source not found: $plugin_src"
        return 0
    fi

    mkdir -p "$plugin_dir"

    if [ -f "$plugin_dst" ] || [ -L "$plugin_dst" ]; then
        local existing_target=""
        if [ -L "$plugin_dst" ]; then
            # readlink -f is GNU-only; fall back to portable resolution
            existing_target="$(readlink -f "$plugin_dst" 2>/dev/null \
                || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$plugin_dst" 2>/dev/null \
                || true)"
        fi
        local canonical_src=""
        canonical_src="$(readlink -f "$plugin_src" 2>/dev/null \
            || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$plugin_src" 2>/dev/null \
            || true)"
        if [ -n "$existing_target" ] && [ -n "$canonical_src" ] \
            && [ "$existing_target" = "$canonical_src" ]; then
            echo "OpenCode plugin already installed: $plugin_dst"
            return 0
        fi
        backup_file "$plugin_dst"
    fi

    case "$MODE" in
        symlink)
            ln -sf "$plugin_src" "$plugin_dst"
            ;;
        copy)
            rm -f "$plugin_dst"
            cp -f "$plugin_src" "$plugin_dst"
            ;;
    esac

    echo "Installed OpenCode plugin: $plugin_dst"
    echo "Ensure notify-opencode.sh is on your PATH"
}

configure_pi() {
    local ext_dir="${PI_EXTENSION_PATH:-$HOME/.pi/agent/extensions}"
    local ext_src="$REPO_DIR/pi-extension/tmux-notify-jump.ts"
    local ext_dst="$ext_dir/tmux-notify-jump.ts"

    if [ ! -f "$ext_src" ]; then
        echo "Warning: Pi extension source not found: $ext_src"
        return 0
    fi

    mkdir -p "$ext_dir"

    if [ -f "$ext_dst" ] || [ -L "$ext_dst" ]; then
        local existing_target=""
        if [ -L "$ext_dst" ]; then
            # readlink -f is GNU-only; fall back to portable resolution
            existing_target="$(readlink -f "$ext_dst" 2>/dev/null \
                || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ext_dst" 2>/dev/null \
                || true)"
        fi
        local canonical_src=""
        canonical_src="$(readlink -f "$ext_src" 2>/dev/null \
            || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ext_src" 2>/dev/null \
            || true)"
        if [ -n "$existing_target" ] && [ -n "$canonical_src" ] \
            && [ "$existing_target" = "$canonical_src" ]; then
            echo "Pi extension already installed: $ext_dst"
            return 0
        fi
        backup_file "$ext_dst"
    fi

    case "$MODE" in
        symlink)
            ln -sf "$ext_src" "$ext_dst"
            ;;
        copy)
            rm -f "$ext_dst"
            cp -f "$ext_src" "$ext_dst"
            ;;
    esac

    echo "Installed Pi extension: $ext_dst"
    echo "Ensure notify-pi.sh is on your PATH"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            shift
            [ $# -gt 0 ] || die "--prefix requires a directory"
            PREFIX="$1"
            ;;
        --bindir)
            shift
            [ $# -gt 0 ] || die "--bindir requires a directory"
            BINDIR="$1"
            ;;
        --symlink)
            MODE="symlink"
            ;;
        --copy)
            MODE="copy"
            ;;
        --configure-codex)
            CONFIGURE_CODEX=1
            ;;
        --configure-claude)
            CONFIGURE_CLAUDE=1
            ;;
        --configure-kimi)
            CONFIGURE_KIMI=1
            ;;
        --configure-grok)
            CONFIGURE_GROK=1
            ;;
        --configure-opencode)
            CONFIGURE_OPENCODE=1
            ;;
        --configure-pi)
            CONFIGURE_PI=1
            ;;
        --configure-tmux)
            CONFIGURE_TMUX=1
            ;;
        --codex-config)
            shift
            [ $# -gt 0 ] || die "--codex-config requires a path"
            CODEX_CONFIG_PATH="$1"
            ;;
        --claude-config)
            shift
            [ $# -gt 0 ] || die "--claude-config requires a path"
            CLAUDE_CONFIG_PATH="$1"
            ;;
        --kimi-config)
            shift
            [ $# -gt 0 ] || die "--kimi-config requires a path"
            KIMI_CONFIG_PATH="$1"
            ;;
        --grok-hooks-path)
            shift
            [ $# -gt 0 ] || die "--grok-hooks-path requires a path"
            GROK_HOOKS_PATH="$1"
            ;;
        --opencode-plugin-path)
            shift
            [ $# -gt 0 ] || die "--opencode-plugin-path requires a path"
            OPENCODE_PLUGIN_PATH="$1"
            ;;
        --pi-extension-path)
            shift
            [ $# -gt 0 ] || die "--pi-extension-path requires a path"
            PI_EXTENSION_PATH="$1"
            ;;
        --tmux-config)
            shift
            [ $# -gt 0 ] || die "--tmux-config requires a path"
            TMUX_CONFIG_PATH="$1"
            ;;
        --tmux-key)
            shift
            [ $# -gt 0 ] || die "--tmux-key requires a key"
            TMUX_KEY="$1"
            ;;
        --uninstall)
            UNINSTALL=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
    shift
done

if ! [[ "$TMUX_KEY" =~ ^[A-Za-z0-9]$ ]]; then
    die "--tmux-key must be one alphanumeric character"
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$BINDIR" ]; then
    BINDIR="$PREFIX/bin"
fi

FILES=(
    tmux-notify-jump
    tmux-notify-jump-lib.sh
    tmux-notify-jump-linux.sh
    tmux-notify-jump-macos.sh
    tmux-notify-jump-hook.sh
    notify-codex.sh
    notify-claude-code.sh
    notify-kimi-code.sh
    notify-grok.sh
    notify-opencode.sh
    notify-pi.sh
)

if [ "$UNINSTALL" -eq 1 ]; then
    if [ "$CONFIGURE_TMUX" -eq 1 ] && [ -x "$BINDIR/tmux-notify-jump" ]; then
        "$BINDIR/tmux-notify-jump" --tmux-uninit || \
            echo "Warning: could not remove state from the running tmux server" >&2
    fi
    for f in "${FILES[@]}"; do
        rm -f "$BINDIR/$f" 2>/dev/null || true
    done
    if [ "$CONFIGURE_TMUX" -eq 1 ]; then
        unconfigure_tmux
    fi
    echo "Uninstalled from: $BINDIR"
    exit 0
fi

mkdir -p "$BINDIR"

for f in "${FILES[@]}"; do
    src="$REPO_DIR/$f"
    dst="$BINDIR/$f"
    [ -f "$src" ] || die "Missing source file: $src"

    chmod +x "$src" 2>/dev/null || true

    case "$MODE" in
        symlink)
            ln -sf "$src" "$dst"
            ;;
        copy)
            if command -v install >/dev/null 2>&1; then
                install -m 755 "$src" "$dst"
            else
                cp -f "$src" "$dst"
                chmod 755 "$dst"
            fi
            ;;
        *)
            die "Invalid MODE: $MODE"
            ;;
    esac
done

echo "Installed to: $BINDIR"
echo "Ensure it's on your PATH, e.g.: export PATH=\"$BINDIR:\$PATH\""

if [ "$CONFIGURE_CODEX" -eq 1 ]; then
    configure_codex "$BINDIR/notify-codex.sh"
fi

if [ "$CONFIGURE_CLAUDE" -eq 1 ]; then
    configure_claude "$BINDIR/notify-claude-code.sh"
fi

if [ "$CONFIGURE_KIMI" -eq 1 ]; then
    configure_kimi "$BINDIR/notify-kimi-code.sh"
fi

if [ "$CONFIGURE_GROK" -eq 1 ]; then
    configure_grok "$BINDIR/notify-grok.sh"
fi

if [ "$CONFIGURE_OPENCODE" -eq 1 ]; then
    configure_opencode
fi

if [ "$CONFIGURE_PI" -eq 1 ]; then
    configure_pi
fi

if [ "$CONFIGURE_TMUX" -eq 1 ]; then
    configure_tmux "$BINDIR/tmux-notify-jump"
fi
