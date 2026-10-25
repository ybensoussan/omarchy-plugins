"""Small helpers shared by the providers: running things, the clipboard, paths."""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
from pathlib import Path

HOME = Path.home()
OMARCHY_PATH = os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy"
STATE = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state") / "omarchy-launcher"
CONFIG = HOME / ".config/omarchy/omarchy-launcher.json"
USER_DIR = HOME / ".config/omarchy/launcher"
PLUGIN_DIR = Path(__file__).resolve().parent.parent


def expand(path: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(str(path or ""))))


def tilde(path: str | Path) -> str:
    """A path the way people write it: ~/Work instead of /home/me/Work."""
    p = str(path)
    home = str(HOME)
    return "~" + p[len(home):] if p == home or p.startswith(home + "/") else p


def have(cmd: str) -> bool:
    return shutil.which(cmd) is not None


# Every command runs in a session of its own (start_new_session), never in the
# backend's: 1Password authorizes op per session, and that authorization is
# meant for the launcher's own op calls only (providers/onepassword.py), not
# for scripts, shell commands or menu conditions that happen to call op.

def run(argv: list[str], timeout: float = 3, input: str | None = None, cwd: str | None = None) -> str:
    """Run a command and return its stdout ("" on any failure)."""
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, input=input, cwd=cwd,
                             start_new_session=True)
        return out.stdout if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def run_ok(argv: list[str], timeout: float = 5) -> tuple[bool, str]:
    """Run a command; (succeeded, stdout + stderr)."""
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, start_new_session=True)
        return out.returncode == 0, (out.stdout + out.stderr).strip()
    except (OSError, subprocess.SubprocessError) as e:
        return False, str(e)


def spawn(argv: list[str], cwd: str | None = None, env: dict | None = None) -> None:
    """Start something that outlives the launcher, in its own session."""
    full_env = None
    if env:
        full_env = dict(os.environ)
        full_env.update(env)
    try:
        subprocess.Popen(argv, cwd=cwd, env=full_env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def spawn_shell(command: str, cwd: str | None = None) -> None:
    """A command line from the user's own config (menu actions, settings): bash -lc."""
    spawn(["bash", "-lc", command], cwd=cwd)


def app(argv: list[str], cwd: str | None = None) -> None:
    """Start a GUI program the way Omarchy does, as its own systemd scope."""
    spawn(["setsid", "uwsm-app", "--"] + argv if have("uwsm-app") else argv, cwd=cwd)


def open_target(target: str) -> None:
    """Open a URL or file with its default application."""
    app(["xdg-open", str(target)])


def terminal(argv: list[str] | None = None, cwd: str | None = None) -> None:
    """Open the default terminal, optionally running a command, in a folder."""
    cmd = ["xdg-terminal-exec"]
    if cwd:
        cmd.append(f"--dir={cwd}")
    app(cmd + (argv or []))


def editor(path: str) -> None:
    spawn(["omarchy-launch-editor", str(path)])


def notify(title: str, body: str = "", icon: str = "") -> None:
    argv = ["notify-send", "-a", "Launcher"]
    if icon:
        argv += ["-i", icon]
    spawn(argv + [title, body] if body else argv + [title])


def copy(text: str, sensitive: bool = False) -> None:
    """Put text on the clipboard. Sensitive text is kept out of Omarchy's history."""
    argv = ["wl-copy", "--type", "text/plain"]
    if sensitive:
        argv.append("--sensitive")
    try:
        subprocess.run(argv, input=text, text=True, timeout=3, start_new_session=True)
    except (OSError, subprocess.SubprocessError):
        pass


def copy_files(paths: list[str]) -> None:
    uris = "".join("file://" + str(Path(p).resolve()) + "\r\n" for p in paths)
    try:
        subprocess.run(["wl-copy", "--type", "text/uri-list"], input=uris, text=True, timeout=3,
                       start_new_session=True)
    except (OSError, subprocess.SubprocessError):
        pass


def paste(text: str) -> None:
    """Type text into the window that had focus before the launcher opened.

    Omarchy's own helper copies it and sends Shift+Insert, which works in
    terminals and GUI apps alike. Wait for the overlay to close first.
    """
    helper = os.path.join(OMARCHY_PATH, "bin/omarchy-clipboard-paste-text")

    def later():
        import time
        time.sleep(0.25)
        spawn([helper, "--shift-insert", text])

    threading.Thread(target=later, daemon=True).start()


def clear_clipboard_after(seconds: int, secret: str) -> None:
    """Empty the clipboard after a while, if it still holds the secret.

    Done here, in the backend, so nothing about the secret (not even a hash)
    ends up in another process's arguments, where `ps` would show it.
    """
    if seconds <= 0:
        return
    import hmac

    def check():
        current = run(["wl-paste", "--no-newline", "--type", "text/plain"], timeout=3)
        if current and hmac.compare_digest(current.encode(), secret.encode()):
            spawn(["wl-copy", "--clear"])

    t = threading.Timer(seconds, check)
    t.daemon = True
    t.start()
