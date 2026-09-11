"""Exercise real terminal writes without touching the developer's terminal."""

import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import time


root = Path(sys.argv[1])
master, slave = pty.openpty()
env = os.environ.copy()
# uv prepends the interpreter directory; keep command stubs ahead of real tools.
env["PATH"] = env["BELL_TEST_PATH"]
env["BELL_TEST_CLIENT_ROWS"] = (
    f"0|20|test|{os.ttyname(slave)}|987654|$1|%9|work"
)
env["TMUX_NOTIFY_DEDUPE_MS"] = "60000"


def receive(expected):
    data = b""
    deadline = time.monotonic() + (5 if expected else 0.2)
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.05)
        if ready:
            data += os.read(master, 4096)
            # Also catch an accidental second write from a detached child.
            deadline = min(deadline, time.monotonic() + 0.2)
    assert data == expected, (data, expected)


def notify(platform, title, flags=(), expected=b"", extra_env=None):
    run_env = env.copy()
    run_env.update(extra_env or {})
    result = subprocess.run(
        [str(root / f"tmux-notify-jump-{platform}.sh"), "--target", "%9",
         "--title", title, "--body", "Test", "--quiet", "--no-activate", *flags],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=run_env, start_new_session=True, timeout=10,
    )
    assert result.returncode == 0, (platform, title, result.stderr)
    assert b"\x07" not in result.stdout + result.stderr
    receive(expected)


try:
    for platform in ("linux", "macos"):
        notify(platform, f"{platform} default")
        notify(platform, f"{platform} explicit", ["--bell"], b"\x07")
        notify(platform, f"{platform} explicit", ["--bell"])
        notify(platform, f"{platform} quiet", expected=b"\x07",
               extra_env={"TMUX_NOTIFY_BELL": "1"})
        notify(platform, f"{platform} dry", ["--bell", "--dry-run"])
        notify(platform, f"{platform} focus", ["--bell", "--focus-only", "--dry-run"])
        # Conflicting config must not override flags when the child reloads it.
        Path(env["TMUX_NOTIFY_CONFIG"]).write_text("TMUX_NOTIFY_BELL=0\n")
        notify(platform, f"{platform} detach on", ["--bell", "--detach"], b"\x07")
        Path(env["TMUX_NOTIFY_CONFIG"]).write_text("TMUX_NOTIFY_BELL=1\n")
        notify(platform, f"{platform} detach off", ["--no-bell", "--detach"])
        Path(env["TMUX_NOTIFY_CONFIG"]).unlink()

    # A real wrapper's redirection and detach still reaches the client device.
    if subprocess.run(["sh", "-c", "command -v jq"], stdout=subprocess.DEVNULL).returncode == 0:
        wrapper_env = dict(env, TMUX_NOTIFY_JUMP_SH=str(root / "tmux-notify-jump-linux.sh"),
                           TMUX_NOTIFY_BELL="1", CODEX_NOTIFY_BELL="1")
        result = subprocess.run(
            [str(root / "notify-codex.sh"), '{"type":"agent-turn-complete"}'],
            env=wrapper_env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True, timeout=10,
        )
        assert result.returncode == 0
        assert b"\x07" not in result.stdout + result.stderr
        receive(b"\x07")

    # Clicking an existing notification must not emit another BEL.
    notify("macos", "callback", ["--bell", "--action-callback",
                                  "--cb-target", "%9", "--cb-no-activate", "1",
                                  "--cb-tmux-socket", env["TMUX_NOTIFY_TMUX_SOCKET"]])
    desktop_log = Path(env["TEST_TEMP_DIR"]) / "desktop"
    assert not desktop_log.exists(), "tmux delivery unexpectedly invoked desktop tools"
    for platform in ("linux", "macos"):
        notify(platform, f"{platform} focus only", ["--bell", "--focus-only"],
               extra_env={"BELL_TEST_ALLOW_DESKTOP": "1"})
        assert desktop_log.exists(), "focus-only should still deliver to the desktop"
        desktop_log.unlink()
finally:
    os.close(slave)
    os.close(master)
