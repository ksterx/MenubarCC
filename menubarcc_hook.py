#!/usr/bin/env python3
"""
MenubarCC hook bridge.

Invoked by Claude Code as a hook command. Reads the JSON event from stdin
and does two things:

1. Maintain ``~/.claude/sessions/<session_id>.waiting`` so the menu bar app
   can show the bouncing "input waiting" animation:
       - Stop              → touch the flag (Claude finished, awaiting input)
       - UserPromptSubmit  → remove the flag (user replied — back to busy)
       - SessionEnd        → remove the flag (no longer relevant)

2. Play a sound for SOUND_EVENTS, subject to the user's config.

3. Spool a banner event file into the app's events/ directory so the menu
   bar app can post a native banner notification. Independent of sound
   muting — gated only by "bannersEnabled".

Config: ~/Library/Application Support/com.ksterx.MenubarCC/hook-config.json
    {
      "muteAll": false,
      "bannersEnabled": true,
      "perEventEnabled": {"Stop": true, "Notification": true, "PermissionRequest": true},
      "soundPaths":      {"Stop": null,  "Notification": null,  "PermissionRequest": null}
    }

Exits 0 in all cases so it never blocks Claude Code's work.
"""

import json
import subprocess
import sys
import time
from pathlib import Path


CONFIG_PATH = (
    Path.home()
    / "Library"
    / "Application Support"
    / "com.ksterx.MenubarCC"
    / "hook-config.json"
)
SESSIONS_DIR = Path.home() / ".claude" / "sessions"
EVENTS_DIR = CONFIG_PATH.parent / "events"

# Default sounds shipped with macOS — no bundled assets required.
DEFAULT_SOUNDS: dict[str, str] = {
    "Stop":              "/System/Library/Sounds/Glass.aiff",
    "Notification":      "/System/Library/Sounds/Tink.aiff",
    "PermissionRequest": "/System/Library/Sounds/Funk.aiff",
}

# Events that may play a sound (user-controllable in the menu)
SOUND_EVENTS = set(DEFAULT_SOUNDS.keys())

# Events that drive the .waiting flag (silent — no sound, no menu entry)
FLAG_EVENTS = {"Stop", "UserPromptSubmit", "SessionEnd"}

# Every event we accept on stdin
SUPPORTED_EVENTS = SOUND_EVENTS | FLAG_EVENTS


def _load_config() -> dict:
    if not CONFIG_PATH.exists():
        return {}
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _update_waiting_flag(event: str, payload: dict) -> None:
    """Touch / remove ~/.claude/sessions/<sid>.waiting based on the event."""
    sid = payload.get("session_id") or payload.get("sessionId")
    if not isinstance(sid, str) or not sid:
        return
    flag = SESSIONS_DIR / f"{sid}.waiting"
    try:
        if event == "Stop":
            SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
            flag.touch(exist_ok=True)
        elif event in ("UserPromptSubmit", "SessionEnd"):
            flag.unlink(missing_ok=True)
    except Exception:
        pass


def _spool_banner_event(event: str, payload: dict, cfg: dict) -> None:
    """Write an event file for the menu bar app to turn into a banner."""
    if not bool(cfg.get("bannersEnabled", True)):
        return
    try:
        EVENTS_DIR.mkdir(parents=True, exist_ok=True)
        data = {
            "event": event,
            "sessionId": payload.get("session_id") or payload.get("sessionId") or "",
            "cwd": payload.get("cwd") or "",
            "message": payload.get("message") or "",
            "ts": time.time(),
        }
        name = f"{time.time_ns()}-{event}"
        tmp = EVENTS_DIR / f"{name}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f)
        tmp.replace(EVENTS_DIR / f"{name}.json")  # atomic — never seen half-written
    except Exception:
        pass


def _resolve_sound_path(event: str, cfg: dict) -> str | None:
    custom = (cfg.get("soundPaths") or {}).get(event)
    if isinstance(custom, str) and custom:
        p = Path(custom).expanduser()
        if p.is_file():
            return str(p)
    default = DEFAULT_SOUNDS.get(event)
    if default and Path(default).is_file():
        return default
    return None


def main() -> None:
    try:
        raw = sys.stdin.read().strip()
        if not raw:
            sys.exit(0)
        payload = json.loads(raw)
        event = payload.get("hook_event_name", "")
        if event not in SUPPORTED_EVENTS:
            sys.exit(0)

        # Update the input-waiting flag for whichever event drives it.
        # This is always done, independent of mute/per-event settings —
        # muting "sound" should not disable the bouncing-crab animation.
        if event in FLAG_EVENTS:
            _update_waiting_flag(event, payload)

        # Only user-visible events go through the sound/banner pipeline.
        if event not in SOUND_EVENTS:
            sys.exit(0)

        cfg = _load_config()

        # Banner spool is independent of sound muting.
        _spool_banner_event(event, payload, cfg)

        if bool(cfg.get("muteAll", False)):
            sys.exit(0)

        per_event = cfg.get("perEventEnabled") or {}
        # Default to enabled when not set so a fresh install still beeps
        if not bool(per_event.get(event, True)):
            sys.exit(0)

        sound_path = _resolve_sound_path(event, cfg)
        if not sound_path:
            sys.exit(0)

        subprocess.Popen(
            ["afplay", sound_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception:
        # Never break Claude Code — fail silently
        pass
    sys.exit(0)


if __name__ == "__main__":
    main()
