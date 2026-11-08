#!/bin/bash
export AGY_DIR="${AGY_DIR:-$HOME/.gemini/antigravity}"
omarchy-agent-usage-update "$@"
python3 "$HOME/.config/omarchy/plugins/sushantkr.agents/update_all_stats.py"
