# OpenClaw Crew — Project Context

## What This Is

A token-optimized 4-agent OpenClaw setup with a single orchestrator (Cooper) that
spawns specialist sub-agents (TARS, Brand, Murph) on demand. Includes a deploy
script for Ubuntu servers, a custom entity-based memory system spec, and full
secrets/security configuration.

## Architecture

```
All inbound → Cooper (Gemini 3.1 Pro) → spawns specialists as needed
  ├── TARS 🔧 (MiniMax M2.5) — coding
  ├── Brand 📧 (Gemini 3.1 Flash-Lite) — email/calendar
  └── Murph 📱 (Gemini 3 Flash) — social/content

Heartbeat cron (every 55m) runs on Gemini 3.1 Flash-Lite (cheap)
All models via OpenRouter (single API key)
Gateway bound to Tailscale only (no open ports on router)
Memory: entity-based system backed by Qdrant (spec in MEMORY-SYSTEM-SPEC.md, not yet built)
```

## Key Design Decisions

- **Single orchestrator + spawned sub-agents** (not 4 full agents). Sub-agents use
  promptMode "minimal" — only AGENTS.md + TOOLS.md injected. Saves ~68% on daily
  token overhead vs 4 full agents.
- **Sub-agents are context-blind.** They cannot see Cooper's conversation, memory,
  or task board. Cooper must pack everything they need into the task description string.
  This is by OpenClaw design (MINIMAL_BOOTSTRAP_ALLOWLIST), not a bug.
- **Heartbeat uses cron, not native heartbeat.** The `heartbeat.model` config override
  is bugged (GitHub issues #9556, #14279, #30894 — heartbeat always uses primary model
  regardless of override). Cron jobs correctly apply model overrides, so we use a cron
  job on Flash-Lite as a workaround.
- **No MEMORY.md auto-injection.** Traditional OpenClaw setups inject MEMORY.md into
  every turn (costs tokens constantly). We use on-demand retrieval instead — currently
  via `memory` CLI backed by Qdrant (not yet built, see MEMORY-SYSTEM-SPEC.md).
- **Obsidian was considered and rejected.** obsidian-cli on headless Ubuntu is unreliable,
  doesn't do semantic search natively, and the official CLI requires Obsidian desktop
  running via IPC. Native memorySearch was considered but append-only markdown scales
  poorly over time. Qdrant entity model chosen for sub-linear growth.
- **Secrets via env vars, never in config files.** openclaw.json uses SecretRef objects
  (`{ source: "env", provider: "default", id: "VAR_NAME" }`). Real values in
  `~/.openclaw/.env` (chmod 600, git-ignored). Deploy script creates systemd service
  with EnvironmentFile pointing to .env.
- **createBootstrapFiles: false** prevents `openclaw configure/setup/doctor --fix`
  from silently overwriting workspace files. Workspaces are git-tracked as additional
  protection.

## File Structure

```
.
├── deploy.sh                    # Full deployment script (--fresh flag for clean install)
├── openclaw.json5               # Main config → copied to ~/.openclaw/openclaw.json
├── .env.example                 # Secrets template → copied to ~/.openclaw/.env
├── .gitignore                   # Excludes secrets, sessions, credentials from git
├── README.md                    # Full setup guide, architecture, cost estimates
├── CLAUDE.md                    # This file — context for Claude Code
├── MEMORY-SYSTEM-SPEC.md        # Build spec for entity memory skill (for Claude Code)
├── reference-merge-logic.py     # Working Python demo of merge/dedup/compact logic
├── workspace-cooper/
│   ├── AGENTS.md                # Orchestrator instructions (~1400 tokens)
│   ├── SOUL.md                  # Persona
│   ├── IDENTITY.md              # Name/emoji
│   ├── USER.md                  # User info (template — needs filling in)
│   ├── TOOLS.md                 # Tool notes
│   ├── HEARTBEAT.md             # Cron heartbeat checklist
│   └── tasks.json               # Kanban task board (starts empty)
├── workspace-tars/
│   ├── AGENTS.md                # Coding specialist instructions
│   └── TOOLS.md
├── workspace-brand/
│   ├── AGENTS.md                # Comms specialist instructions
│   └── TOOLS.md
└── workspace-murph/
    ├── AGENTS.md                # Social/content specialist instructions
    └── TOOLS.md
```

## deploy.sh

13-step deployment script for Ubuntu servers. Handles:
1. Node.js 22+
2. OpenClaw (npm, reinstalls on --fresh)
3. Docker
4. Qdrant container (localhost:6333, API key auth, persistent volume)
5. entity-memory CLI (not yet published — will fail gracefully)
6. GOG (Google Workspace CLI for Brand)
7. Tailscale (secure remote access, no open ports)
8. UFW firewall (SSH + port 18789 restricted to tailscale0 interface)
9. Workspace directories + vault structure
10. Copy workspace files (skip if existing)
11. Git-track all workspaces
12. Secrets setup (.env from template, chmod 600, .gitignore)
13. Systemd user service with EnvironmentFile

SCRIPT_DIR is defined at line 5 (top of script). `set -euo pipefail` means
unbound variables are fatal — every variable must be defined before use.

The --fresh flag: stops gateway, backs up ~/.openclaw/ to tarball, nukes it,
uninstalls and reinstalls OpenClaw npm package, then runs full clean install.

## Model Map (via OpenRouter)

| Agent | Model | Input/M | Output/M |
|-------|-------|---------|----------|
| Cooper (conversations) | google/gemini-3.1-pro-preview | $2.00 | $12.00 |
| Cooper (heartbeat cron) | google/gemini-3.1-flash-lite | $0.25 | $1.50 |
| TARS (coding) | minimax/minimax-m2.5 | $0.30 | $1.20 |
| Brand (email/cal) | google/gemini-3.1-flash-lite | $0.25 | $1.50 |
| Murph (social) | google/gemini-3-flash | $0.50 | $3.00 |

All agents have `anthropic/claude-sonnet-4-5` as fallback.

## Memory System (NOT YET BUILT)

MEMORY-SYSTEM-SPEC.md contains the full build spec for a Qdrant-backed entity
memory system. Key concepts:

- **Entities**: long-term knowledge, upserted in place (person:alice, project:dashboard)
- **Events**: raw observations, auto-expire after 30 days
- **Decisions**: permanent architectural/strategic choices
- **Merge logic**: cosine similarity > 0.9 = duplicate → reinforce (bump hit_count).
  Longer text wins. No LLM needed — pure embeddings + code.
- **Compaction**: when facts > 20, score by frequency × recency × permanence, keep top 20.
- **CLI**: `memory event`, `memory store`, `memory search`, `memory extract`, `memory compact`, `memory expire`, `memory export`, `memory list`, `memory get`, `memory delete`, `memory stats`, `memory init`, `memory import`

reference-merge-logic.py has a working demo of the merge algorithm.
The skill should be built as a standalone Python package publishable to ClawHub.

## OpenClaw Conventions To Know

- `openclaw configure` / `openclaw doctor --fix` can silently overwrite workspace files.
  We set `createBootstrapFiles: false` to prevent this.
- Workspace files injected per turn: AGENTS.md, SOUL.md, TOOLS.md, IDENTITY.md,
  USER.md, HEARTBEAT.md, MEMORY.md (if present). Capped by bootstrapMaxChars (6000)
  and bootstrapTotalMaxChars (20000).
- Sub-agents only get AGENTS.md + TOOLS.md (hardcoded MINIMAL_BOOTSTRAP_ALLOWLIST).
- Platform formatting: no markdown tables on WhatsApp/Discord. No headers on WhatsApp.
- `trash` > `rm` in all agent instructions.
- Skills metadata costs ~24 tokens/turn per enabled skill.

## When Editing deploy.sh

- Script uses `set -euo pipefail` — every variable must be defined, every command
  must succeed, pipe failures are caught.
- SCRIPT_DIR defined at line 5 — available everywhere.
- All file copies use `copy_if_missing` (won't overwrite existing).
- Docker commands need the user in the `docker` group (`newgrp docker` or re-login
  after install).
- UFW rules depend on tailscale0 interface existing — script skips firewall config
  if Tailscale isn't connected yet and tells user to rerun.
- Qdrant ports bound to 127.0.0.1 only (not network-accessible).
- Systemd service uses `EnvironmentFile` for secrets — never in ExecStart or .bashrc.

## When Editing Workspace Files

- Cooper's AGENTS.md is ~1400 tokens (~5700 chars). bootstrapMaxChars is 6000.
  Don't exceed this or it gets truncated.
- Sub-agent workspaces only need AGENTS.md + TOOLS.md. Other files are ignored
  during spawned runs.
- tasks.json starts empty. Cooper creates tasks at runtime.
- USER.md is a template — user fills in their name/timezone.
