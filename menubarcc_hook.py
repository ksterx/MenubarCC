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
      "responsePreviewEnabled": true,
      "volume": 1.0,
      "perEventEnabled": {"Stop": true, "Notification": true, "PermissionRequest": true},
      "soundPaths":      {"Stop": null,  "Notification": null,  "PermissionRequest": null}
    }

Exits 0 in all cases so it never blocks Claude Code's work.
"""

import json
import os
import re
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

# Hidden helper sessions (e.g. claude-mem's background "observer" sessions
# run under ~/.claude-mem) are not the user's work — never sound or banner.
BACKGROUND_CWD_ROOT = Path.home() / ".claude-mem"

# Default sounds shipped with macOS — no bundled assets required.
DEFAULT_SOUNDS: dict[str, str] = {
    "Stop":              "/System/Library/Sounds/Glass.aiff",
    "Notification":      "/System/Library/Sounds/Tink.aiff",
    "PermissionRequest": "/System/Library/Sounds/Funk.aiff",
}

DEFAULT_VOLUME = 1.0

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


def _has_running_background_task(payload: dict) -> bool:
    """True if the turn ended only to wait on a background agent.

    Claude Code reports live background work in the Stop payload's
    ``background_tasks``. A running entry means the main agent will resume on
    its own — it is NOT waiting for the user — so it must not raise the
    "input waiting" flag (which would make Clawd bounce for no reason).
    """
    tasks = payload.get("background_tasks")
    if not isinstance(tasks, list):
        return False
    return any(isinstance(t, dict) and t.get("status") == "running" for t in tasks)


def _update_waiting_flag(event: str, payload: dict) -> None:
    """Touch / remove ~/.claude/sessions/<sid>.waiting based on the event."""
    sid = payload.get("session_id") or payload.get("sessionId")
    if not isinstance(sid, str) or not sid:
        return
    flag = SESSIONS_DIR / f"{sid}.waiting"
    try:
        if event == "Stop":
            if _has_running_background_task(payload):
                # Finished our part but a background agent is still working.
                flag.unlink(missing_ok=True)
            else:
                SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
                flag.touch(exist_ok=True)
        elif event in ("UserPromptSubmit", "SessionEnd"):
            flag.unlink(missing_ok=True)
    except Exception:
        pass


# Response-preview tunables. A banner body is only a few lines, so a short
# prefix is all that's useful; reading the whole transcript to fill it is not
# worth the hook's 5s budget.
PREVIEW_MAX_CHARS = 140
TRANSCRIPT_TAIL_CAP = 2_000_000  # bytes read from the transcript's tail, max

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
_WS_RE = re.compile(r"\s+")


def _clean_preview(text: str) -> str | None:
    """Flatten a raw assistant message into a single short banner line."""
    text = _WS_RE.sub(" ", _ANSI_RE.sub("", text)).strip()
    if not text:
        return None
    if len(text) > PREVIEW_MAX_CHARS:
        text = text[: PREVIEW_MAX_CHARS - 1].rstrip() + "…"
    return text


def _text_from_content(content) -> str | None:
    """Join the user-visible text blocks of an assistant message."""
    if isinstance(content, str):
        return content.strip() or None
    if not isinstance(content, list):
        return None
    parts = [
        b["text"]
        for b in content
        if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)
    ]
    joined = "".join(parts).strip()
    return joined or None


def _extract_from_transcript(path: str) -> str | None:
    """Find the last main-session assistant text in a JSONL transcript.

    Reads only the file's tail (up to TRANSCRIPT_TAIL_CAP), walks entries
    newest-first, skips subagent (sidechain) turns and text-less turns
    (e.g. a trailing tool call), and returns the first real text found.
    """
    try:
        p = Path(path).expanduser()
        if not p.is_file():
            return None
        size = p.stat().st_size
        if size == 0:
            return None
        to_read = min(size, TRANSCRIPT_TAIL_CAP)
        with open(p, "rb") as f:
            f.seek(size - to_read)
            data = f.read(to_read)
        # If we began mid-file, the first line is likely partial — drop it.
        if to_read < size:
            nl = data.find(b"\n")
            data = data[nl + 1:] if nl != -1 else b""
        for raw in reversed(data.split(b"\n")):
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw.decode("utf-8"))
            except Exception:
                continue  # partial or non-JSON line — skip
            if not isinstance(entry, dict):
                continue
            if entry.get("isSidechain") is True:
                continue
            if entry.get("type") != "assistant":
                continue
            msg = entry.get("message")
            if not isinstance(msg, dict):
                continue
            text = _text_from_content(msg.get("content"))
            if text:
                return text
    except Exception:
        return None
    return None


def _response_preview(payload: dict) -> str | None:
    """Best-effort preview of the model's last response for a Stop banner.

    Prefers the payload's own fields (no I/O), falling back to reading the
    transcript tail. Returns None so the caller keeps the fixed banner text.
    """
    for src in (payload.get("last_assistant_message"), payload.get("message")):
        if isinstance(src, str) and src.strip():
            return _clean_preview(src)
    tp = payload.get("transcript_path")
    if isinstance(tp, str) and tp:
        text = _extract_from_transcript(tp)
        if text:
            return _clean_preview(text)
    return None


def _spool_banner_event(event: str, payload: dict, cfg: dict) -> None:
    """Write an event file for the menu bar app to turn into a banner."""
    if not bool(cfg.get("bannersEnabled", True)):
        return
    try:
        EVENTS_DIR.mkdir(parents=True, exist_ok=True)
        message = payload.get("message") or ""
        # For a finished response, optionally surface the reply's opening.
        if event == "Stop" and bool(cfg.get("responsePreviewEnabled", True)):
            preview = _response_preview(payload)
            if preview:
                message = preview
        data = {
            "event": event,
            "sessionId": payload.get("session_id") or payload.get("sessionId") or "",
            "cwd": payload.get("cwd") or "",
            "message": message,
            "ts": time.time(),
        }
        name = f"{time.time_ns()}-{event}"
        tmp = EVENTS_DIR / f"{name}.tmp"
        # 0600 — the body may quote the model's reply; keep it user-private.
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
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


def _resolve_volume(cfg: dict) -> float:
    volume = cfg.get("volume", DEFAULT_VOLUME)
    if not isinstance(volume, (int, float)):
        return DEFAULT_VOLUME
    return max(0.0, min(1.0, float(volume)))


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

        cwd = payload.get("cwd") or ""
        if cwd and Path(cwd).is_relative_to(BACKGROUND_CWD_ROOT):
            sys.exit(0)

        # A Stop that only ended to wait on a background agent isn't a
        # user-facing "done" moment — suppress its sound and banner, matching
        # the .waiting flag handled above.
        if event == "Stop" and _has_running_background_task(payload):
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

        volume = _resolve_volume(cfg)
        subprocess.Popen(
            ["afplay", "-v", str(volume), sound_path],
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
