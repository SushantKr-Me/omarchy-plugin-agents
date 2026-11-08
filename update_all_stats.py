#!/usr/bin/env python3
import glob
import json
import os
import subprocess
from pathlib import Path

# 1. Update AGY stats
try:
    env = os.environ.copy()
    env["AGY_DIR"] = str(Path.home() / ".gemini/antigravity")
    out = subprocess.check_output(
        ["/usr/share/omarchy/bin/omarchy-agent-usage-agy", "--force"],
        env=env, text=True, stderr=subprocess.DEVNULL, timeout=10
    )
    if out.strip():
        data = json.loads(out)
        target = Path.home() / ".local/state/omarchy/agents/usage/agy.json"
        with open(target, "w") as f:
            f.write(json.dumps(data, indent=2))
except Exception as e:
    pass

# 2. Output tasks JSON for QML
import sys
sys.path.insert(0, str(Path.home() / ".config/omarchy/plugins/sushantkr.agents"))
import agent_tasks
tasks = agent_tasks.collect_all_tasks()
task_file = Path.home() / ".local/state/omarchy/agents/tasks.json"
with open(task_file, "w") as f:
    json.dump(tasks, f, indent=2)
