#!/usr/bin/env python3
"""Claude Code session monitor — macOS menu bar with animations."""

import json
import math
import os
import plistlib
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path

# Ship our own CA bundle — py2app's bundled Python can't read the system
# trust store, so urllib HTTPS fails with "Could not reach…" without this.
try:
    import certifi
    _SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where())
except Exception:
    _SSL_CONTEXT = ssl.create_default_context()

import AppKit
import objc
from PIL import Image, ImageDraw
import rumps

# ServiceManagement is only available inside a real .app bundle on macOS 13+.
# Importing it from a dev / source run is fine; the helpers below gracefully
# return None when no app context is available.
try:
    import ServiceManagement
except ImportError:
    ServiceManagement = None


def _resource(filename: str) -> Path:
    """Resolve a resource path, whether running from an app bundle or source."""
    if getattr(sys, "frozen", False):
        base = Path(sys.executable).parent.parent / "Resources"
    else:
        base = Path(__file__).parent
    return base / filename


SESSIONS_DIR = Path.home() / ".claude" / "sessions"
CRAB_SRC     = _resource("cc-menubar-icon.png")
FRAMES_DIR   = Path.home() / "Library" / "Caches" / "com.ksterx.MenubarCC" / "frames"

APP_SUPPORT_DIR   = Path.home() / "Library" / "Application Support" / "com.ksterx.MenubarCC"
APP_SETTINGS_PATH = APP_SUPPORT_DIR / "settings.json"     # app-only prefs (animFps)
HOOK_CONFIG_PATH  = APP_SUPPORT_DIR / "hook-config.json"  # shared with menubarcc_hook.py

# Where the hook bridge gets installed. Both the script and the Claude Code
# settings file live under ~/.claude.
HOOK_SCRIPT_SRC      = _resource("menubarcc_hook.py")
HOOK_SCRIPT_INSTALL  = Path.home() / ".claude" / "hooks" / "scripts" / "menubarcc_hook.py"
CLAUDE_SETTINGS_PATH = Path.home() / ".claude" / "settings.json"
HOOK_COMMAND_MARKER  = "menubarcc_hook.py"   # used to detect our entries

STUCK_SECS   = 600          # default "stuck" threshold; overridable in settings.json
REFRESH_SECS = 10

# Stuck detection is on by default; toggleable from Advanced Settings.
STUCK_DETECTION_DEFAULT = True
# Selectable "stuck" thresholds for the Advanced Settings menu (label, seconds).
STUCK_PRESETS: list[tuple[str, int]] = [
    ("5 minutes",  300),
    ("10 minutes", 600),
    ("15 minutes", 900),
    ("30 minutes", 1800),
    ("60 minutes", 3600),
]

# The HTML "latest" endpoint 302-redirects to /releases/tag/<tag>. Unlike the
# JSON API it is not rate-limited per IP, so update checks never hit HTTP 403.
GITHUB_LATEST_REDIRECT = "https://github.com/ksterx/claude-code-menubar/releases/latest"
GITHUB_RELEASES_URL    = "https://github.com/ksterx/claude-code-menubar/releases"

# Delay before the first-run install prompt so the menu bar icon
# appears first and the user knows which app is asking.
FIRST_RUN_PROMPT_DELAY = 2.0

# Animation speed presets (seconds per frame). Lower = faster.
SPEED_PRESETS: list[tuple[str, float]] = [
    ("Very Slow", 0.30),
    ("Slow",      0.20),
    ("Normal",    0.12),
    ("Fast",      0.08),
    ("Very Fast", 0.04),
]
DEFAULT_ANIM_FPS = 0.12

# Hook events that surface in the menu (user can toggle / pick a sound for these).
CONTROLLED_HOOK_EVENTS: list[tuple[str, str]] = [
    ("Stop",              "Stop (response end)"),
    ("Notification",      "Notification"),
    ("PermissionRequest", "Permission Request"),
]

# Every event we register in ~/.claude/settings.json on Install. The two extra
# events (UserPromptSubmit, SessionEnd) are silent — they exist only to keep
# the ~/.claude/sessions/<sid>.waiting flag in sync so the crab bounces while
# Claude is waiting for the user.
INSTALLED_HOOK_EVENTS: list[str] = [e for e, _ in CONTROLLED_HOOK_EVENTS] + [
    "UserPromptSubmit",
    "SessionEnd",
]


# ── Frame generation ─────────────────────────────────────────────────────────

def build_frames(crab: Image.Image) -> dict:
    FRAMES_DIR.mkdir(parents=True, exist_ok=True)
    # Crop transparent padding so the crab fits the menu bar tightly
    bbox = crab.getbbox()
    if bbox:
        crab = crab.crop(bbox)
    cw, ch = crab.size
    PAD     = 36                # horizontal travel padding
    CW      = cw + PAD          # canvas width
    CH      = 44                # canvas height (menu bar baseline)
    cy      = (CH - ch) // 2   # vertical center

    def blank():
        return Image.new("RGBA", (CW, CH), (0, 0, 0, 0))

    # ── Walking (right → left) ───────────────────────────────────────────
    WALK_N = 14
    walk = []
    for i in range(WALK_N):
        t = i / (WALK_N - 1)
        x = int((1 - t) * PAD)   # PAD → 0
        img = blank()
        img.paste(crab, (x, cy), crab)
        p = FRAMES_DIR / f"walk_{i:02d}.png"
        img.save(p)
        walk.append(str(p))

    # ── Bouncing (waiting for user) ──────────────────────────────────────
    BOUNCE_N = 12
    BOUNCE_H = 8                 # up to 8px upward
    bounce = []
    for i in range(BOUNCE_N):
        t = math.sin(math.pi * i / BOUNCE_N)   # 0 → 1 → 0
        y = cy - int(t * BOUNCE_H)
        img = blank()
        img.paste(crab, (PAD // 2, y), crab)
        p = FRAMES_DIR / f"bounce_{i:02d}.png"
        img.save(p)
        bounce.append(str(p))

    # ── Pulsing (stuck — alpha flash) ────────────────────────────────────
    PULSE_N = 8
    pulse = []
    for i in range(PULSE_N):
        alpha = int(128 + 127 * math.sin(2 * math.pi * i / PULSE_N))
        img = blank()
        frame = crab.copy()
        r, g, b, a = frame.split()
        a = a.point(lambda v: int(v * alpha / 255))
        frame = Image.merge("RGBA", (r, g, b, a))
        img.paste(frame, (PAD // 2, cy), frame)
        p = FRAMES_DIR / f"pulse_{i:02d}.png"
        img.save(p)
        pulse.append(str(p))

    # ── Static (idle) ────────────────────────────────────────────────────
    static = blank()
    static.paste(crab, (PAD // 2, cy), crab)
    sp = FRAMES_DIR / "static.png"
    static.save(sp)

    return {"walk": walk, "bounce": bounce, "pulse": pulse, "static": str(sp)}


# ── Session loading ──────────────────────────────────────────────────────────

def _now_ms() -> float:
    return time.time() * 1000


def fmt_age(secs: float) -> str:
    m = int(secs // 60)
    return f"{m}m" if m < 60 else f"{m // 60}h{m % 60:02d}m"


def load_sessions(
    stuck_secs: int = STUCK_SECS, stuck_enabled: bool = STUCK_DETECTION_DEFAULT
) -> list[dict]:
    result = []
    for f in SESSIONS_DIR.glob("*.json"):
        try:
            d = json.loads(f.read_text())
            age_s = (_now_ms() - d.get("statusUpdatedAt", _now_ms())) / 1000
            sid   = d.get("sessionId", "")
            d["_age_s"]   = age_s
            d["_stuck"]   = (
                stuck_enabled
                and d.get("status") == "busy"
                and age_s > stuck_secs
            )
            d["_waiting"] = (
                d.get("status") == "idle"
                and (SESSIONS_DIR / f"{sid}.waiting").exists()
            )
            d["_dir"] = Path(d.get("cwd", "?")).name or d.get("cwd", "?")
            result.append(d)
        except Exception:
            pass
    return sorted(result, key=lambda x: x.get("updatedAt", 0), reverse=True)


def make_header(text: str) -> rumps.MenuItem:
    item = rumps.MenuItem(text)
    item.set_callback(None)
    return item


# ── Config file I/O ──────────────────────────────────────────────────────────

def _read_json(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _write_json_atomic(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    tmp.replace(path)


def load_hook_config() -> dict:
    """MenubarCC hook config — single source of truth, shared with menubarcc_hook.py."""
    return _read_json(HOOK_CONFIG_PATH)


def save_hook_config(cfg: dict) -> None:
    _write_json_atomic(HOOK_CONFIG_PATH, cfg)


def update_hook_config(**changes) -> None:
    """Merge given keys into the hook config and save.
    Nested dicts (perEventEnabled, soundPaths) are dict-merged, not replaced."""
    cfg = load_hook_config()
    for key, value in changes.items():
        if key in ("soundPaths", "perEventEnabled") and isinstance(value, dict):
            sub = dict(cfg.get(key) or {})
            sub.update(value)
            cfg[key] = sub
        else:
            cfg[key] = value
    save_hook_config(cfg)


def is_event_enabled(cfg: dict, event: str) -> bool:
    """Default to True so a fresh install beeps until the user changes it."""
    return bool((cfg.get("perEventEnabled") or {}).get(event, True))


# ── Hook installer ───────────────────────────────────────────────────────────

def _hook_command_for_event() -> str:
    # `python3` keeps us independent of any specific Python install location.
    return f"python3 {HOOK_SCRIPT_INSTALL}"


def _read_claude_settings() -> dict:
    return _read_json(CLAUDE_SETTINGS_PATH)


def _backup_claude_settings() -> Path | None:
    """Copy ~/.claude/settings.json to a timestamped sibling file. Returns the backup path."""
    if not CLAUDE_SETTINGS_PATH.exists():
        return None
    # Stamp by mtime to avoid depending on wall-clock import (kept simple)
    import time as _t
    stamp = _t.strftime("%Y%m%d-%H%M%S", _t.localtime())
    backup = CLAUDE_SETTINGS_PATH.with_suffix(f".json.bak.{stamp}")
    backup.write_bytes(CLAUDE_SETTINGS_PATH.read_bytes())
    return backup


def _hooks_section_has_menubarcc(section: list) -> bool:
    """Return True if the given Claude Code hook section already references our script."""
    for group in section or []:
        for h in (group or {}).get("hooks", []) or []:
            cmd = h.get("command", "") if isinstance(h, dict) else ""
            if HOOK_COMMAND_MARKER in cmd:
                return True
    return False


def hooks_are_installed() -> bool:
    """True when both the script is in place and settings.json references it."""
    if not HOOK_SCRIPT_INSTALL.exists():
        return False
    settings = _read_claude_settings()
    hooks_root = settings.get("hooks") or {}
    return all(
        _hooks_section_has_menubarcc(hooks_root.get(event) or [])
        for event in INSTALLED_HOOK_EVENTS
    )


def install_hooks() -> tuple[bool, str]:
    """
    Copy the bridge script and register it in ~/.claude/settings.json.
    Returns (ok, message).
    """
    try:
        if not HOOK_SCRIPT_SRC.is_file():
            return False, f"Bundled hook script not found at {HOOK_SCRIPT_SRC}"

        HOOK_SCRIPT_INSTALL.parent.mkdir(parents=True, exist_ok=True)
        HOOK_SCRIPT_INSTALL.write_bytes(HOOK_SCRIPT_SRC.read_bytes())
        HOOK_SCRIPT_INSTALL.chmod(0o755)

        backup = _backup_claude_settings()
        settings = _read_claude_settings()
        hooks_root = dict(settings.get("hooks") or {})

        command = _hook_command_for_event()
        for event in INSTALLED_HOOK_EVENTS:
            section = list(hooks_root.get(event) or [])
            if not _hooks_section_has_menubarcc(section):
                section.append({
                    "hooks": [{
                        "type":    "command",
                        "command": command,
                        "timeout": 5000,
                        "async":   True,
                    }],
                })
            hooks_root[event] = section

        settings["hooks"] = hooks_root
        _write_json_atomic(CLAUDE_SETTINGS_PATH, settings)

        msg = "Hooks installed."
        if backup:
            msg += f" Previous settings backed up to {backup.name}."
        return True, msg
    except Exception as e:
        return False, f"Install failed: {e}"


def uninstall_hooks() -> tuple[bool, str]:
    """Remove our entries from settings.json and delete the installed script."""
    try:
        backup = _backup_claude_settings()
        settings = _read_claude_settings()
        hooks_root = dict(settings.get("hooks") or {})

        for event in list(hooks_root.keys()):
            cleaned = []
            for group in hooks_root.get(event) or []:
                inner = [
                    h for h in (group or {}).get("hooks", []) or []
                    if HOOK_COMMAND_MARKER not in (h.get("command", "") if isinstance(h, dict) else "")
                ]
                if inner:
                    new_group = dict(group)
                    new_group["hooks"] = inner
                    cleaned.append(new_group)
            if cleaned:
                hooks_root[event] = cleaned
            else:
                hooks_root.pop(event, None)

        if hooks_root:
            settings["hooks"] = hooks_root
        else:
            settings.pop("hooks", None)
        _write_json_atomic(CLAUDE_SETTINGS_PATH, settings)

        if HOOK_SCRIPT_INSTALL.exists():
            HOOK_SCRIPT_INSTALL.unlink()

        msg = "Hooks uninstalled."
        if backup:
            msg += f" Previous settings backed up to {backup.name}."
        return True, msg
    except Exception as e:
        return False, f"Uninstall failed: {e}"


def load_app_settings() -> dict:
    return _read_json(APP_SETTINGS_PATH)


def save_app_settings(cfg: dict) -> None:
    _write_json_atomic(APP_SETTINGS_PATH, cfg)


# ── Login item (Launch at Login) ─────────────────────────────────────────────

# SMAppService.Status raw values (from <ServiceManagement/SMAppService.h>)
_SM_STATUS_NOT_REGISTERED   = 0
_SM_STATUS_ENABLED          = 1
_SM_STATUS_REQUIRES_APPROVAL = 2
_SM_STATUS_NOT_FOUND         = 3


def _login_item_service():
    if ServiceManagement is None:
        return None
    try:
        return ServiceManagement.SMAppService.mainAppService()
    except Exception:
        return None


def login_item_available() -> bool:
    """True when SMAppService is usable (real bundle on macOS 13+)."""
    return _login_item_service() is not None and getattr(sys, "frozen", False)


def login_item_enabled() -> bool:
    svc = _login_item_service()
    if svc is None:
        return False
    try:
        return int(svc.status()) == _SM_STATUS_ENABLED
    except Exception:
        return False


def set_login_item(enabled: bool) -> tuple[bool, str]:
    """Register or unregister this app as a login item. Returns (ok, message)."""
    svc = _login_item_service()
    if svc is None:
        return False, "Launch at Login is unavailable in this build."
    try:
        if enabled:
            ok, err = svc.registerAndReturnError_(None)
        else:
            ok, err = svc.unregisterAndReturnError_(None)
    except Exception as e:
        return False, f"Login item error: {e}"
    if ok:
        return True, "Enabled" if enabled else "Disabled"
    desc = ""
    if err is not None:
        try:
            desc = str(err.localizedDescription())
        except Exception:
            desc = str(err)
    return False, desc or "Unknown error"


# ── Update check ─────────────────────────────────────────────────────────────

def get_current_version() -> str:
    """CFBundleShortVersionString from the running bundle, or 'dev' from source."""
    if getattr(sys, "frozen", False):
        plist = Path(sys.executable).parent.parent / "Info.plist"
        try:
            with open(plist, "rb") as f:
                return plistlib.load(f).get("CFBundleShortVersionString", "dev")
        except Exception:
            return "dev"
    return "dev"


def _parse_version(v: str) -> tuple:
    """Loose semver parsing. 'v1.2.0' / '1.2' → tuple of ints."""
    parts = v.lstrip("v").strip().split(".")
    out = []
    for p in parts:
        try:
            out.append(int(p.split("-")[0]))  # strip pre-release suffix if any
        except ValueError:
            break
    return tuple(out) if out else (0,)


def compare_versions(a: str, b: str) -> int:
    """-1 if a<b, 0 if equal, 1 if a>b."""
    pa, pb = _parse_version(a), _parse_version(b)
    return (pa > pb) - (pa < pb)


def fetch_latest_release() -> tuple[str, str] | None:
    """Resolve the latest release tag via the rate-limit-free HTML redirect.

    Returns (tag, html_url) or None on failure. We only read the redirected
    URL, not the page body, so this stays cheap.
    """
    try:
        req = urllib.request.Request(
            GITHUB_LATEST_REDIRECT,
            headers={"User-Agent": "MenubarCC-update-check"},
        )
        with urllib.request.urlopen(req, timeout=10, context=_SSL_CONTEXT) as resp:
            final_url = resp.geturl()
        # …/releases/tag/v1.4.0  →  v1.4.0   (no /tag/ means there's no release)
        if "/releases/tag/" not in final_url:
            return None
        tag = final_url.rstrip("/").rsplit("/releases/tag/", 1)[-1]
        if not tag or "/" in tag:
            return None
        return (tag, final_url)
    except Exception:
        return None


def _dmg_url_for(tag: str) -> str:
    """Release DMGs follow a fixed naming scheme: MenubarCC-<version>.dmg."""
    version = tag.removeprefix("v")
    return f"{GITHUB_RELEASES_URL}/download/{tag}/MenubarCC-{version}.dmg"


# Runs after MenubarCC quits: swap the .app atomically, then relaunch.
# No literal braces here so str.format only touches the named fields.
_SWAP_SCRIPT = """#!/bin/bash
PID={pid}
NEW="{new}"
TARGET="{target}"
TMP="{tmp}"
BACKUP="$TARGET.old-$$"
# Wait (up to ~60s) for MenubarCC to actually quit. Swapping a running bundle
# would corrupt the live process, so if it never exits we abort and leave the
# current install untouched.
for _ in $(seq 1 300); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$PID" 2>/dev/null; then
  rm -rf "$TMP"
  exit 0
fi
if mv "$TARGET" "$BACKUP" 2>/dev/null; then
  if ditto "$NEW" "$TARGET"; then
    xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
    rm -rf "$BACKUP"
  else
    # New copy failed mid-way — drop the partial and restore the original.
    rm -rf "$TARGET"
    mv "$BACKUP" "$TARGET" 2>/dev/null || true
  fi
fi
# Safety net: never leave the user without an app at the canonical path.
if [ ! -d "$TARGET" ] && [ -d "$BACKUP" ]; then
  mv "$BACKUP" "$TARGET" 2>/dev/null || true
fi
if [ -d "$TARGET" ]; then
  open "$TARGET"
fi
rm -rf "$TMP"
"""


def perform_update(tag: str) -> str | None:
    """Download the DMG for `tag`, stage the new .app, and hand off a detached
    helper that swaps it in once we quit. Returns None on success (caller must
    then quit the app), or a human-readable error string on failure.
    """
    if not getattr(sys, "frozen", False):
        return "Updates only apply to the installed app, not when run from source."

    bundle = Path(sys.executable).resolve().parents[2]  # …/MenubarCC.app
    if bundle.suffix != ".app":
        return "Could not locate the app bundle to update."
    if not os.access(bundle, os.W_OK) or not os.access(bundle.parent, os.W_OK):
        return ("No permission to replace the app at\n"
                f"{bundle}.\nUpdate manually instead.")

    tmp = Path(tempfile.mkdtemp(prefix="menubarcc-update-"))
    dmg = tmp / "update.dmg"
    mount = tmp / "mnt"
    staging = tmp / "staged"
    handed_off = False  # once the swap helper owns `tmp`, we must not delete it
    try:
        req = urllib.request.Request(
            _dmg_url_for(tag), headers={"User-Agent": "MenubarCC-update-check"}
        )
        with urllib.request.urlopen(req, timeout=120, context=_SSL_CONTEXT) as resp, \
                open(dmg, "wb") as out:
            shutil.copyfileobj(resp, out)

        mount.mkdir()
        subprocess.run(
            ["hdiutil", "attach", str(dmg), "-nobrowse", "-readonly",
             "-mountpoint", str(mount)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            apps = list(mount.glob("*.app"))
            if not apps:
                return "The downloaded disk image contains no app."
            staging.mkdir()
            new_app = staging / apps[0].name
            subprocess.run(
                ["ditto", str(apps[0]), str(new_app)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        finally:
            subprocess.run(
                ["hdiutil", "detach", str(mount), "-quiet"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )

        # Strip quarantine so the swapped app launches without a Gatekeeper prompt.
        subprocess.run(
            ["xattr", "-dr", "com.apple.quarantine", str(new_app)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

        helper = tmp / "swap.sh"
        helper.write_text(_SWAP_SCRIPT.format(
            pid=os.getpid(), new=new_app, target=bundle, tmp=tmp))
        subprocess.Popen(
            ["/bin/bash", str(helper)], start_new_session=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        handed_off = True
        return None
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return ("Couldn't find the download for this release. "
                    "Open the release page to update manually.")
        return f"Update failed: HTTP {e.code}"
    except Exception as e:
        return f"Update failed: {e}"
    finally:
        if not handed_off:
            shutil.rmtree(tmp, ignore_errors=True)


class _MainThreadDispatcher(AppKit.NSObject):
    """Hop a Python callable back to the main thread.

    PyObjC keeps a reference to `self` for the lifetime of the
    performSelectorOnMainThread call, so a freshly alloc'd dispatcher
    survives until the selector fires.
    """

    def initWithCallback_(self, callback):
        self = objc.super(_MainThreadDispatcher, self).init()
        if self is None:
            return None
        self._cb = callback
        return self

    def fire_(self, _):
        try:
            self._cb()
        except Exception:
            pass


def run_on_main(callback) -> None:
    disp = _MainThreadDispatcher.alloc().initWithCallback_(callback)
    disp.performSelectorOnMainThread_withObject_waitUntilDone_("fire:", None, False)


# ── Switch-style NSMenuItem (Tailscale-style) ────────────────────────────────

class _SwitchHandler(AppKit.NSObject):
    """Bridge NSSwitch's target/action selector to a Python callable."""

    def initWithCallback_(self, callback):
        self = objc.super(_SwitchHandler, self).init()
        if self is None:
            return None
        self._cb = callback
        return self

    def toggled_(self, sender):
        self._cb(bool(sender.state()))


def make_switch_view(
    title: str,
    subtitle: str,
    on: bool,
    on_toggle,
    handler_holder: list,
) -> AppKit.NSView:
    """Build an NSView with title + subtitle + NSSwitch, for use as NSMenuItem.view."""
    width, height = 260, 40
    view = AppKit.NSView.alloc().initWithFrame_(((0, 0), (width, height)))

    title_field = AppKit.NSTextField.labelWithString_(title)
    title_field.setFrame_(((14, 19), (180, 16)))
    title_field.setFont_(AppKit.NSFont.menuFontOfSize_(13))
    view.addSubview_(title_field)

    sub_field = AppKit.NSTextField.labelWithString_(subtitle)
    sub_field.setFrame_(((14, 4), (180, 14)))
    sub_field.setFont_(AppKit.NSFont.systemFontOfSize_(10))
    sub_field.setTextColor_(AppKit.NSColor.secondaryLabelColor())
    view.addSubview_(sub_field)

    sw = AppKit.NSSwitch.alloc().init()
    sw.setFrame_(((width - 56, 9), (40, 22)))
    sw.setState_(1 if on else 0)
    handler = _SwitchHandler.alloc().initWithCallback_(on_toggle)
    handler_holder.append(handler)  # keep alive (NSSwitch holds a weak ref to target)
    sw.setTarget_(handler)
    sw.setAction_("toggled:")
    view.addSubview_(sw)

    return view


# ── App ──────────────────────────────────────────────────────────────────────

ICON_PT_H = 16   # menu bar icon height in points


class CCApp(rumps.App):
    def _set_frame(self, path: str):
        """Set the status bar icon, sizing the NSImage in points."""
        img = AppKit.NSImage.alloc().initWithContentsOfFile_(path)
        w_px, h_px = img.size().width, img.size().height
        scale  = ICON_PT_H / h_px
        pt_w   = w_px * scale
        img.setSize_(AppKit.NSSize(pt_w, ICON_PT_H))
        self._icon_nsimage = img
        try:
            self._nsapp.setStatusBarIcon()
        except AttributeError:
            pass

    def __init__(self, frames: dict):
        super().__init__("", icon=frames["static"], template=False, quit_button=None)
        self._frames       = frames
        self._anim_idx     = 0
        self._anim_state   = "idle"   # "walk" | "bounce" | "pulse" | "idle"
        self._known_stuck: set[str] = set()

        # Keep NSObject handlers alive while their menu items are mounted
        self._switch_handlers: list = []

        # Restore animation speed from user settings (fall back to default)
        app_cfg = load_app_settings()
        self._anim_fps = float(app_cfg.get("animFps", DEFAULT_ANIM_FPS))

        # Restore stuck-detection prefs (enabled + threshold)
        self._stuck_enabled = bool(
            app_cfg.get("stuckEnabled", STUCK_DETECTION_DEFAULT)
        )
        self._stuck_secs = int(app_cfg.get("stuckSecs", STUCK_SECS))

        # Hold a Timer instance so we can change `interval` at runtime
        self._anim_timer = rumps.Timer(self._animate, self._anim_fps)
        self._anim_timer.start()

        self._refresh(None)           # initial data load

        # First-run: if the hook isn't installed yet, ask the user once.
        self._first_run_timer = rumps.Timer(
            self._first_run_tick, FIRST_RUN_PROMPT_DELAY
        )
        self._first_run_timer.start()

    # ── Animation (interval driven by user-selected speed) ──────────────
    def _animate(self, _):
        state = self._anim_state
        if state == "walk":
            seq = self._frames["walk"]
        elif state == "bounce":
            seq = self._frames["bounce"]
        elif state == "pulse":
            seq = self._frames["pulse"]
        else:
            return   # idle is static — nothing to do

        self._anim_idx = (self._anim_idx + 1) % len(seq)
        self._set_frame(seq[self._anim_idx])

    # ── Data refresh (every 10s) ─────────────────────────────────────────
    @rumps.timer(REFRESH_SECS)
    def _refresh(self, _):
        ss      = load_sessions(self._stuck_secs, self._stuck_enabled)
        stuck   = [s for s in ss if s["_stuck"]]
        busy    = [s for s in ss if s.get("status") == "busy" and not s["_stuck"]]
        waiting = [s for s in ss if s["_waiting"]]
        idle    = [s for s in ss if s.get("status") == "idle" and not s["_waiting"]]

        # ── Decide animation state ───────────────────────────────────
        # Priority: WAITING > STUCK > ACTIVE > IDLE.
        # WAITING wins because the user can only unblock Claude by replying.
        # The menu-bar title stays empty in every state — "stuck" is signalled
        # only by the pulsing (alpha-flash) crab, with no count or warning badge.
        self.title = ""
        if waiting:
            new_state = "bounce"
        elif stuck:
            new_state = "pulse"
        elif busy:
            new_state = "walk"
        else:
            new_state = "idle"
            self.icon  = self._frames["static"]

        if new_state != self._anim_state:
            self._anim_state = new_state
            self._anim_idx   = 0

        if new_state == "idle":
            self._set_frame(self._frames["static"])

        # ── stuck notification ──────────────────────────────────────
        for s in stuck:
            sid = s.get("sessionId", "")
            if sid not in self._known_stuck:
                rumps.notification(
                    title="Claude Code — Stuck session",
                    subtitle=s["_dir"],
                    message=f"busy for {fmt_age(s['_age_s'])} with no updates",
                )
        self._known_stuck = {s.get("sessionId", "") for s in stuck}

        # ── Rebuild menu ─────────────────────────────────────────────
        items: list = []

        def add_section(label: str, sessions: list[dict]):
            if not sessions:
                return
            items.append(make_header(label))
            for s in sessions:
                items.append(rumps.MenuItem(
                    f"        {s['_dir']}   {fmt_age(s['_age_s'])}"
                ))
            items.append(None)

        if not ss:
            items.append(rumps.MenuItem("No sessions"))
            items.append(None)
        else:
            add_section(f"⚠   STUCK   ·  {len(stuck)}",   stuck)
            add_section(f"⏵   ACTIVE  ·  {len(busy)}",    busy)
            add_section(f"⏸  WAITING  ·  {len(waiting)}", waiting)
            add_section(f"·   IDLE    ·  {len(idle)}",    idle)

        # Top-level Tailscale-style toggle for quick mute control
        cfg = load_hook_config()
        muted = bool(cfg.get("muteAll", False))
        # New handler list — releasing old handlers is safe because the old
        # menu items they were bound to are about to be removed by menu.clear()
        self._switch_handlers = []
        notif_switch = rumps.MenuItem("Notifications")
        notif_switch._menuitem.setView_(
            make_switch_view(
                title="Notifications",
                subtitle="Muted" if muted else "On",
                on=not muted,
                on_toggle=self._on_notifications_switch,
                handler_holder=self._switch_handlers,
            )
        )
        items.append(notif_switch)

        items.append(self._build_advanced_menu())
        items.append(None)
        items.append(rumps.MenuItem("Check for Updates…", callback=self._check_updates))
        items.append(rumps.MenuItem("Quit", callback=rumps.quit_application))

        self.menu.clear()
        for item in items:
            self.menu.add(item)

    # ── Advanced Settings (umbrella menu) ───────────────────────────────
    def _build_advanced_menu(self) -> rumps.MenuItem:
        root = rumps.MenuItem("Advanced Settings")
        root.add(self._build_sound_menu())
        root.add(self._build_speed_menu())
        root.add(self._build_stuck_menu())
        root.add(None)
        root.add(self._build_login_item_entry())
        root.add(None)
        root.add(self._build_install_menu())
        return root

    # ── Launch at Login ─────────────────────────────────────────────────
    def _build_login_item_entry(self) -> rumps.MenuItem:
        if not login_item_available():
            item = rumps.MenuItem("Launch at Login (run from /Applications)")
            item.set_callback(None)
            return item
        item = rumps.MenuItem("Launch at Login", callback=self._toggle_login_item)
        item.state = 1 if login_item_enabled() else 0
        return item

    def _toggle_login_item(self, sender):
        # state == 1 means currently enabled → user wants to disable it
        new_value = not bool(sender.state)
        ok, msg = set_login_item(new_value)
        if not ok:
            rumps.alert(title="Launch at Login", message=msg)
        self._refresh(None)

    # ── Notification Sounds submenu ─────────────────────────────────────
    def _build_sound_menu(self) -> rumps.MenuItem:
        cfg = load_hook_config()
        muted = bool(cfg.get("muteAll", False))
        sound_paths = cfg.get("soundPaths") or {}

        root = rumps.MenuItem("Notification Sounds")

        for event, label in CONTROLLED_HOOK_EVENTS:
            enabled = is_event_enabled(cfg, event)
            item = rumps.MenuItem(label, callback=self._make_toggle_event_callback(event))
            item.state = 1 if enabled else 0
            if muted:
                item.set_callback(None)  # grey out while master-muted
            root.add(item)
        root.add(None)

        for event, _label in CONTROLLED_HOOK_EVENTS:
            current = sound_paths.get(event)
            suffix = f"  ({Path(current).name})" if current else "  (Default)"
            choose = rumps.MenuItem(
                f"Choose {event} sound…{suffix}",
                callback=self._make_choose_sound_callback(event),
            )
            root.add(choose)
        root.add(None)
        root.add(rumps.MenuItem("Reset All Custom Sounds", callback=self._reset_all_sounds))

        return root

    # ── First-run install prompt ────────────────────────────────────────
    def _first_run_tick(self, _):
        # Single-shot — stop ourselves so we don't fire again.
        self._first_run_timer.stop()

        app_cfg = load_app_settings()
        if app_cfg.get("installPromptShown", False):
            return  # already asked once
        if hooks_are_installed():
            return  # nothing to do

        # Mark as shown *before* opening the dialog so a crash or force-quit
        # during the dialog doesn't trap the user in an endless prompt loop.
        app_cfg["installPromptShown"] = True
        save_app_settings(app_cfg)

        choice = rumps.alert(
            title="Welcome to MenubarCC",
            message=(
                "MenubarCC can install a small hook into Claude Code so the menu "
                "bar can control notification sounds and show when Claude is "
                "waiting for your input. You can also do this later from "
                "Advanced Settings."
            ),
            ok="Install Hook",
            cancel="Not Now",
        )
        if choice == 1:
            ok, msg = install_hooks()
            rumps.alert(title="MenubarCC", message=msg)
            self._refresh(None)

    # ── Install / Uninstall submenu ─────────────────────────────────────
    def _build_install_menu(self) -> rumps.MenuItem:
        if hooks_are_installed():
            return rumps.MenuItem(
                "Uninstall Hook from Claude Code",
                callback=self._uninstall_hook,
            )
        return rumps.MenuItem(
            "Install Hook into Claude Code…",
            callback=self._install_hook,
        )

    def _install_hook(self, _sender):
        if rumps.alert(
            title="Install MenubarCC hook?",
            message=(
                "This will copy menubarcc_hook.py into ~/.claude/hooks/scripts/ "
                "and register Stop / Notification / PermissionRequest hooks in "
                "~/.claude/settings.json. A timestamped backup of settings.json "
                "will be created first."
            ),
            ok="Install",
            cancel="Cancel",
        ) != 1:
            return
        ok, msg = install_hooks()
        rumps.alert(title="MenubarCC", message=msg)
        self._refresh(None)

    def _uninstall_hook(self, _sender):
        if rumps.alert(
            title="Uninstall MenubarCC hook?",
            message=(
                "This will remove our entries from ~/.claude/settings.json "
                "(creating a backup first) and delete the installed "
                "menubarcc_hook.py script."
            ),
            ok="Uninstall",
            cancel="Cancel",
        ) != 1:
            return
        ok, msg = uninstall_hooks()
        rumps.alert(title="MenubarCC", message=msg)
        self._refresh(None)

    # ── Speed submenu ──────────────────────────────────────────────────
    def _build_speed_menu(self) -> rumps.MenuItem:
        root = rumps.MenuItem("Speed")
        current = self._anim_fps
        # Check the preset closest to the current value
        closest = min(SPEED_PRESETS, key=lambda p: abs(p[1] - current))[1]
        for label, fps in SPEED_PRESETS:
            item = rumps.MenuItem(label, callback=self._make_set_speed_callback(fps))
            item.state = 1 if abs(fps - closest) < 1e-6 else 0
            root.add(item)
        return root

    # ── Stuck Detection submenu ─────────────────────────────────────────
    def _build_stuck_menu(self) -> rumps.MenuItem:
        root = rumps.MenuItem("Stuck Detection")
        toggle = rumps.MenuItem(
            "Detect stuck sessions", callback=self._toggle_stuck_detection
        )
        toggle.state = 1 if self._stuck_enabled else 0
        root.add(toggle)
        root.add(None)
        for label, secs in STUCK_PRESETS:
            item = rumps.MenuItem(
                label, callback=self._make_set_stuck_secs_callback(secs)
            )
            item.state = 1 if secs == self._stuck_secs else 0
            if not self._stuck_enabled:
                item.set_callback(None)   # grey out the thresholds while off
            root.add(item)
        return root

    # ── Update check ────────────────────────────────────────────────────
    def _check_updates(self, _sender):
        def worker():
            result = fetch_latest_release()
            run_on_main(lambda: self._on_update_result(result))
        threading.Thread(target=worker, daemon=True).start()

    def _on_update_result(self, result):
        current = get_current_version()
        if result is None:
            rumps.alert(
                title="MenubarCC",
                message="Could not reach GitHub. Check your network connection.",
            )
            return
        tag, _url = result
        if not tag:
            rumps.alert(
                title="MenubarCC",
                message="GitHub returned no release info. Try again later.",
            )
            return
        if compare_versions(tag, f"v{current}") <= 0:
            rumps.alert(
                title="MenubarCC",
                message=f"You're up to date (v{current}).",
            )
            return
        if rumps.alert(
            title=f"MenubarCC {tag} is available",
            message=(
                f"You're on v{current}. Download and install it now? "
                "MenubarCC will restart automatically."
            ),
            ok="Update Now",
            cancel="Later",
        ) == 1:
            self._apply_update(tag)

    def _apply_update(self, tag):
        rumps.notification("MenubarCC", "Updating…",
                           "Downloading the new version in the background.")

        def worker():
            err = perform_update(tag)
            run_on_main(lambda: self._on_update_applied(err))

        threading.Thread(target=worker, daemon=True).start()

    def _on_update_applied(self, err):
        if err is None:
            # Helper is waiting for us to quit, then swaps and relaunches.
            rumps.quit_application()
            return
        if rumps.alert(
            title="MenubarCC",
            message=f"{err}\n\nOpen the release page to update manually?",
            ok="Open Release Page",
            cancel="Cancel",
        ) == 1:
            webbrowser.open(GITHUB_RELEASES_URL)

    # ── Notification sound callbacks ───────────────────────────────────
    def _on_notifications_switch(self, switch_on: bool):
        # Switch ON  → notifications enabled  → muteAll = False
        # Switch OFF → notifications muted    → muteAll = True
        update_hook_config(muteAll=not switch_on)
        # Don't rebuild the menu here — that would close it mid-toggle.
        # The subtitle ("On"/"Muted") updates on the next refresh tick.

    def _make_toggle_event_callback(self, event_name: str):
        def _cb(sender):
            # state == 1 means enabled (checked) → user wants to disable it
            new_enabled = not bool(sender.state)
            update_hook_config(perEventEnabled={event_name: new_enabled})
            self._refresh(None)
        return _cb

    def _make_choose_sound_callback(self, event_name: str):
        def _cb(_sender):
            path = self._prompt_sound_file(event_name)
            if path:
                update_hook_config(soundPaths={event_name: path})
                self._refresh(None)
        return _cb

    def _reset_all_sounds(self, _sender):
        cfg = load_hook_config()
        cfg["soundPaths"] = {event: None for event, _ in CONTROLLED_HOOK_EVENTS}
        save_hook_config(cfg)
        self._refresh(None)

    def _prompt_sound_file(self, event_name: str) -> str | None:
        """Open NSOpenPanel to pick a sound file. Returns None on cancel."""
        AppKit.NSApp.activateIgnoringOtherApps_(True)
        panel = AppKit.NSOpenPanel.openPanel()
        panel.setTitle_(f"Choose a sound file for {event_name}")
        panel.setCanChooseFiles_(True)
        panel.setCanChooseDirectories_(False)
        panel.setAllowsMultipleSelection_(False)
        panel.setAllowedFileTypes_(["mp3", "wav", "m4a", "aiff", "aac", "caf"])
        if panel.runModal() != 1:
            return None
        urls = panel.URLs()
        if not urls:
            return None
        return str(urls[0].path())

    # ── Speed callbacks ────────────────────────────────────────────────
    def _make_set_speed_callback(self, fps: float):
        def _cb(_sender):
            self._anim_fps = fps
            self._anim_timer.stop()
            self._anim_timer.interval = fps
            self._anim_timer.start()
            settings = load_app_settings()
            settings["animFps"] = fps
            save_app_settings(settings)
            self._refresh(None)
        return _cb

    # ── Stuck-detection callbacks ───────────────────────────────────────
    def _toggle_stuck_detection(self, sender):
        # state == 1 means currently enabled → user wants to turn it off
        self._stuck_enabled = not bool(sender.state)
        settings = load_app_settings()
        settings["stuckEnabled"] = self._stuck_enabled
        save_app_settings(settings)
        self._refresh(None)

    def _make_set_stuck_secs_callback(self, secs: int):
        def _cb(_sender):
            self._stuck_secs = secs
            settings = load_app_settings()
            settings["stuckSecs"] = secs
            save_app_settings(settings)
            self._refresh(None)
        return _cb


# ── Entry point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    crab   = Image.open(str(CRAB_SRC)).convert("RGBA")
    frames = build_frames(crab)
    CCApp(frames).run()
