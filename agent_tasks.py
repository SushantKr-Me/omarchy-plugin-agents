#!/usr/bin/env python3
import glob
import json
import os
import sqlite3
from pathlib import Path

def get_agy_info():
    db_path = Path.home() / ".gemini/antigravity/conversation_summaries.db"
    if not db_path.exists():
        return None
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        cursor = conn.cursor()
        cursor.execute("""
            SELECT title, preview, status, not_fully_idle, datetime(last_modified_time)
            FROM conversation_summaries
            WHERE title != '' OR preview != ''
            ORDER BY last_modified_time DESC
            LIMIT 1;
        """)
        row = cursor.fetchone()
        conn.close()
        if row:
            title = (row[0] or row[1] or "").strip()
            is_busy = bool(row[3]) or "RUNNING" in str(row[2])
            status = "Working..." if is_busy else "Idle"
            return {"task": title, "status": status}
    except Exception:
        pass
    return None

def get_codex_info():
    db_path = Path.home() / ".codex/state_5.sqlite"
    if not db_path.exists():
        return None
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        cursor = conn.cursor()
        cursor.execute("SELECT title, updated_at FROM threads ORDER BY updated_at DESC LIMIT 1;")
        row = cursor.fetchone()
        conn.close()
        if row and row[0]:
            return {"task": row[0].strip(), "status": "Idle"}
    except Exception:
        pass
    return None

def get_copilot_info():
    db_path = Path.home() / ".copilot/session-store.db"
    if not db_path.exists():
        return None
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        cursor = conn.cursor()
        cursor.execute("SELECT summary, updated_at FROM sessions ORDER BY updated_at DESC LIMIT 1;")
        row = cursor.fetchone()
        conn.close()
        if row and row[0]:
            return {"task": row[0].strip(), "status": "Idle"}
    except Exception:
        pass
    return None

def get_deepseek_info():
    pattern = str(Path.home() / ".dsh/sessions/*/*/session.v4.jsonl.zstd")
    sessions = glob.glob(pattern)
    if not sessions:
        return None
    latest = max(sessions, key=os.path.getmtime)
    import subprocess
    try:
        out = subprocess.check_output(f"zstdcat '{latest}' | grep '\"type\":\"session/title\"' | tail -n 1", shell=True, text=True)
        if out:
            data = json.loads(out)
            title = data.get("data", {}).get("title")
            if title:
                return {"task": title.strip(), "status": "Idle"}
    except Exception:
        pass
    return None

def get_claude_info():
    # Check ~/.claude transcripts if any exist
    pattern = str(Path.home() / ".claude/projects/**/*.jsonl")
    sessions = glob.glob(pattern, recursive=True)
    if not sessions:
        return None
    latest = max(sessions, key=os.path.getmtime)
    try:
        with open(latest, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                d = json.loads(line)
                if d.get("type") == "session_title" or d.get("title"):
                    return {"task": (d.get("title") or "").strip(), "status": "Idle"}
    except Exception:
        pass
    return None

def collect_all_tasks():
    tasks = {}
    agy = get_agy_info()
    if agy: tasks["agy"] = agy
    codex = get_codex_info()
    if codex: tasks["codex"] = codex
    copilot = get_copilot_info()
    if copilot: tasks["copilot"] = copilot
    deepseek = get_deepseek_info()
    if deepseek: tasks["deepseek"] = deepseek
    claude = get_claude_info()
    if claude: tasks["claude"] = claude
    return tasks

if __name__ == "__main__":
    print(json.dumps(collect_all_tasks(), indent=2))
