# 🤖 My Agents Tracker (`omarchy-plugin-agents`)

A native AI model and subscription usage tracker for [Omarchy Linux](https://omarchy.org)'s Quickshell bar (`omarchy-shell`). Monitor active quotas, reset schedules, velocity/pace meters, token consumption, and prepaid account balances for 20+ AI providers in one unified bar panel.

![My Agents](omarchy-plugin-agents.png)

## Overview & Basics

My Agents provides a status bar capsule and dropdown panel displaying real-time metrics across all your AI developer accounts. Instead of logging into dozens of provider dashboards, monitor your rate-limits, weekly/monthly resets, and burning speed directly from your status bar.

## Features

- **🌐 Broad AI Provider Support**:
  - Automatically discovers and tracks sessions from:
    - **Anthropic Claude Code** (Sonnet 3.5, Opus 3, Haiku)
    - **OpenAI Codex & ChatGPT** (GPT-4o, o1, o3-mini)
    - **xAI Grok** (Grok 2, Grok 3)
    - **Google Antigravity (AGY)**
    - **Moonshot Kimi**, **Cursor**, **GitHub Copilot**, **Devin**
    - **Ollama** (local inference models)
    - **DeepSeek**, **OpenRouter**, **Fireworks**, **Minimax**, **Qwen**, and more.

- **📈 Rate-Limit & Pace Meters**:
  - Live progress bars for each model and window tier.
  - Precise countdown timers until quota resets (daily, weekly, monthly).
  - Velocity indicators show whether your current pacing will exhaust tokens before the reset window.
  - Warning colors when usage exceeds 80% or 95% of available allowance.

- **👥 Multi-Account & Autoswitch**:
  - Lists individual accounts for providers with multiple keys or subscriptions.
  - Distinct *ACTIVE* indicator showing which profile receives new CLI sessions.
  - Optional **Autoswitch**: seamlessly transitions to a secondary account when primary quota depletes.

- **💳 Prepaid Credit Ledger**:
  - For usage-based and pay-as-you-go providers (e.g. OpenRouter, Fireworks):
  - Fuel-gauge style balance bar showing remaining funds versus spent amounts.
  - Real-time spend tracking and balance alerts.

- **🔄 Multi-Machine Usage Sync**:
  - Export machine-local snapshots and aggregate usage across all your laptops, workstations, and servers using Syncthing, Dropbox, or rsync.

## Bar Widget Controls

| Action | Result |
|---|---|
| **Left-Click** | Opens / Closes the My Agents panel |
| **Hover** | Displays total tokens used today and active model stats |
| **+ Button (Panel)** | Quick-add account for Claude, Codex, Grok, or custom providers |

---

## Installation & Setup

```bash
omarchy plugin add https://github.com/SushantKr-Me/omarchy-plugin-agents.git --enable
```

## License

MIT License © Sushant Kumar
