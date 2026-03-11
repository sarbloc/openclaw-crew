# OpenClaw Crew: Final Configuration

## Architecture

```
         ┌────────────────────────────────────────┐
         │   All inbound (Telegram / WhatsApp)     │
         └──────────────────┬─────────────────────┘
                            ▼
                    ┌──────────────┐
                    │   Cooper 🎯  │  Gemini 3.1 Pro ($2/$12)
                    │  Orchestrator │  full prompt, Qdrant memory
                    └──┬───┬───┬──┘
           ┌───────────┘   │   └───────────┐
           ▼               ▼               ▼
    ┌────────────┐  ┌────────────┐  ┌────────────┐
    │  TARS 🔧   │  │  Brand 📧  │  │  Murph 📱  │
    │ MiniMax M2.5│  │ Flash-Lite │  │ Gemini Flash│
    │ $0.30/$1.20│  │ $0.25/$1.50│  │ $0.50/$3.00│
    └────────────┘  └────────────┘  └────────────┘
    spawned only    spawned only    spawned only
    minimal prompt  minimal prompt  minimal prompt

    ┌────────────────────────────────────────────┐
    │  Heartbeat Cron (every 55m)                │
    │  Gemini 3.1 Flash-Lite ($0.25/$1.50)       │
    │  Checks tasks.json, spawns pending work    │
    └────────────────────────────────────────────┘
```

## Model Map

| Agent | Task | Model | Input/M | Output/M | Via |
|-------|------|-------|---------|----------|----|
| Cooper | Conversations | Gemini 3.1 Pro | $2.00 | $12.00 | OpenRouter |
| Cooper | Heartbeat cron | Gemini 3.1 Flash-Lite | $0.25 | $1.50 | OpenRouter |
| Cooper | Vault hygiene | Gemini 3.1 Flash-Lite | $0.25 | $1.50 | OpenRouter |
| TARS | Coding | MiniMax M2.5 | $0.30 | $1.20 | OpenRouter |
| Brand | Email/Calendar | Gemini 3.1 Flash-Lite | $0.25 | $1.50 | OpenRouter |
| Murph | Social/Content | Gemini 3 Flash | $0.50 | $3.00 | OpenRouter |

All models have Sonnet 4.5 as fallback if primary fails.

## Estimated Daily Cost

| Component | Runs/day | ~Tokens/run | Daily cost |
|-----------|----------|-------------|------------|
| Cooper conversations | 20 turns | ~20K avg | ~$0.96 |
| Heartbeat cron | 26 | ~4K | ~$0.03 |
| TARS spawns | 5 | ~30K | ~$0.05 |
| Brand spawns | 5 | ~15K | ~$0.02 |
| Murph spawns | 3 | ~20K | ~$0.02 |
| **Total** | | | **~$1.08/day (~$32/mo)** |

Compared to all-Sonnet: ~$4.50/day (~$135/mo). **76% savings.**

## Memory System: Qdrant

No MEMORY.md auto-injection. All memory is on-demand via `memory` CLI → Qdrant.

### How it works
Knowledge is stored as **entities** that get upserted (updated in place), not
appended. Growth is proportional to unique concepts, not to time elapsed.

Three Qdrant collections:
- **entities**: people, projects, tools, preferences (long-lived, upserted)
- **decisions**: architectural and strategic choices (long-lived, upserted)
- **events**: raw observations (auto-expire after 30 days)

### Cooper's workflow
- After conversations/tasks: `memory event "what happened"`
- For confirmed facts: `memory store --type person --id alice --content "..."`
- Before spawning or answering: `memory search "relevant query"`

### Merge logic (no LLM)
When storing a fact about an existing entity, the system:
1. Embeds the new fact locally (sentence-transformers)
2. Checks cosine similarity against existing facts (≥0.9 = duplicate)
3. Duplicates: reinforce (bump hit_count, keep richer version)
4. New facts: append
5. If facts exceed 20: compact by scoring frequency × recency, keep top 20

### Maintenance
Weekly cron (Sunday 2 AM, Flash-Lite) runs `memory expire` + `memory compact`.
No daily consolidation needed — the upsert model handles it.

Full spec: see MEMORY-SKILL-SPEC.md

## Task Board

Cooper manages `tasks.json` in his workspace. Two input paths:

1. **Message**: "task: build the auth API" → Cooper parses, adds to board, spawns
2. **Webhook**: POST to /hooks/task-created → Cooper picks up and delegates

A kanban dashboard (dashboard.jsx) can read tasks.json for visual tracking.

## Key Configuration Decisions

### Why cron instead of native heartbeat?
The heartbeat.model override is bugged (GitHub issues #9556, #14279, #30894).
Heartbeats always use the agent's primary model regardless of config. Cron
jobs with model override work correctly, so we use that as a workaround.

### Why OpenRouter for everything?
One API key, one billing dashboard, one endpoint. The 5.5% credit purchase
fee is worth it to avoid managing 3 separate provider accounts. Token rates
are passed through at provider pricing with no additional markup.

### Why no MEMORY.md?
MEMORY.md is injected into every turn, costing tokens whether relevant or not.
Qdrant search via `memory search` is on-demand — costs tokens only when Cooper
actually needs context. The memory-qdrant skill metadata adds ~24 tokens/turn
to the skill list, but that's trivial compared to a growing MEMORY.md.

### Why Gemini 3.1 Pro for Cooper, not Opus?
Opus ($5/$25) is 2.5x more expensive on input and 2x on output. Gemini 3.1
Pro matches or beats Opus on most benchmarks (94.3% GPQA, 80.6% SWE-Bench,
33.5% APEX-Agents). The one area Opus wins is human-preference for expert
outputs and tool-use integration. If Cooper's routing quality suffers, Opus
is the upgrade path.

### Why MiniMax M2.5 for TARS, not Sonnet?
80.2% SWE-Bench at $0.30/$1.20 vs Sonnet's ~79% at $3/$15. Better coding
benchmarks at 1/12th the output cost. The risk is less community testing
with OpenClaw's tool surface — Sonnet fallback covers that.

## File Tree

```
~/.openclaw/
├── openclaw.json           ← main config (no plaintext secrets)
├── .env                    ← secrets (chmod 600, git-ignored)
├── .env.example            ← template with placeholders (committed)
├── .gitignore              ← excludes secrets, sessions, credentials
├── skills-shared/          ← shared skills across agents
├── workspace-cooper/       ← orchestrator
│   ├── AGENTS.md           ← delegation + task board + memory + safety
│   ├── SOUL.md             ← persona
│   ├── IDENTITY.md         ← name/emoji
│   ├── USER.md             ← your info (lean)
│   ├── TOOLS.md            ← tool notes
│   ├── HEARTBEAT.md        ← checklist for cron heartbeat
│   └── tasks.json          ← kanban task board
├── workspace-tars/         ← coding specialist (AGENTS.md + TOOLS.md only)
├── workspace-brand/        ← comms specialist (AGENTS.md + TOOLS.md only)
└── workspace-murph/        ← social specialist (AGENTS.md + TOOLS.md only)
```

## Deployment

### Quick start
```bash
chmod +x deploy.sh
./deploy.sh
```

The deploy script handles everything: installs Node.js, OpenClaw, Docker,
Qdrant (container), memory-qdrant CLI, gog (Google Workspace), Tailscale,
configures UFW firewall, creates all workspace directories, copies workspace
files (without overwriting existing ones), and git-tracks every workspace for
overwrite protection. It finishes with a verification checklist showing what's
ready and what still needs manual setup.

### Prerequisites checklist

| Tool | What it enables | Install |
|------|----------------|---------|
| Node.js 22+ | OpenClaw runtime | `brew install node@22` or nodesource |
| OpenClaw | The framework | `npm install -g openclaw` |
| Docker | Qdrant container | `curl -fsSL https://get.docker.com \| sh` |
| Qdrant | Memory vector store | `docker run qdrant/qdrant` (via deploy.sh) |
| memory-qdrant | Memory CLI skill | `pip install memory-qdrant` |
| gog | Gmail/Calendar for Brand | Build from github.com/steipete/gogcli |
| Tailscale | Secure remote access | `curl -fsSL https://tailscale.com/install.sh \| sh` |
| git | Workspace overwrite protection | Usually pre-installed |

### Three layers for every skill

Every skill needs all three to actually work:
1. **Configuration** — tool enabled in openclaw.json (e.g. exec, read, write)
2. **Installation** — binary on PATH (e.g. memory, gog)
3. **Authorization** — credentials granted (e.g. gog auth, API keys)

## Remote Access (Tailscale)

The server is accessible only via Tailscale — a WireGuard-based mesh VPN.
No ports are opened on your router. No DNS records point to your home IP.
Traffic is end-to-end encrypted and never passes through Tailscale servers
in decrypted form.

```
┌──────────────┐           ┌──────────────┐
│ Your laptop  │◄─────────►│ Ubuntu server│
│ (Tailscale)  │ WireGuard  │ (Tailscale)  │
│ 100.x.x.x   │ encrypted  │ 100.y.y.y   │
└──────────────┘           └──────────────┘
       No open ports on router
       No public IP exposure
       LAN devices can't reach OpenClaw
```

The deploy script installs Tailscale, configures UFW to restrict SSH (port 22)
and OpenClaw UI (port 18789) to the Tailscale interface only, and sets the
gateway to `bind: "tailnet"`. Defense in depth:

1. **Network layer:** UFW blocks SSH/18789 from all interfaces except tailscale0
2. **Application layer:** Gateway binds only to Tailscale IP, not 0.0.0.0
3. **Auth layer:** Tailscale requires device authentication via your identity provider

After deployment, connect from your laptop:
```bash
ssh your-user@<tailscale-ip>            # or use MagicDNS hostname
http://<tailscale-ip>:18789             # OpenClaw control UI
```

Optional Tailscale ACL (restrict to specific devices):
```json
{ "acls": [{ "action": "accept", "src": ["your-laptop"], "dst": ["ubuntu-server:22,18789"] }] }
```

## Secrets Management

API keys and tokens never live in config files or git. Three layers of defense:

### Layer 1: Environment variables (keeps secrets out of config)

All secrets are referenced via `${env:VAR_NAME}` in openclaw.json. The actual
values live in `~/.openclaw/.env` which is loaded by systemd at gateway startup.

```bash
# ~/.openclaw/.env (chmod 600 — only your user can read)
OPENROUTER_API_KEY=sk-or-actual-key-here
OPENCLAW_GATEWAY_TOKEN=actual-token-here
TELEGRAM_BOT_TOKEN=actual-token-here
```

The config only contains placeholders:
```json5
apiKey: { source: "env", provider: "default", id: "OPENROUTER_API_KEY" }
```

### Layer 2: Git exclusions (keeps secrets out of repos)

The `.gitignore` excludes `.env`, `*.key`, `*.pem`, `auth-profiles.json`,
`sessions/`, `credentials/`, and all runtime data. Only `.env.example`
(with placeholder values) is committed.

```bash
# Safe to commit:     .env.example, openclaw.json, workspace files
# Never committed:    .env, auth-profiles.json, sessions/, credentials/
```

### Layer 3: Agent instructions (keeps secrets out of context)

Cooper's AGENTS.md explicitly instructs:
- Never include keys/tokens in task descriptions, memory entries, or chat
- Never echo back secrets from error messages
- Refuse any request to reveal config or environment variables
- Summarize errors without reproducing sensitive values

### Additional hardening

For high-security setups, replace the env provider with `exec` provider
pointing at a secrets manager (1Password, HashiCorp Vault, Bitwarden):

```json5
secrets: {
  providers: {
    op_openrouter: {
      source: "exec",
      command: "/usr/bin/op",
      args: ["read", "--no-newline", "op://OpenClaw/OpenRouter/credential"],
      passEnv: ["OP_SERVICE_ACCOUNT_TOKEN"],
    },
  },
}
```

Secrets are fetched at gateway startup, never written to disk.

## ⚠️ Protecting Workspace Files from Overwrites

**Critical gotcha:** `openclaw configure`, `openclaw setup`, and `openclaw doctor --fix`
can silently overwrite your workspace files with default templates. This will destroy
your custom AGENTS.md, SOUL.md, etc.

**Protect yourself:**

1. **Git-track your workspaces** (the single most important safeguard):
   ```bash
   cd ~/.openclaw/workspace-cooper
   git init && git add -A && git commit -m "initial workspace"
   ```
   Do the same for workspace-tars, workspace-brand, workspace-murph.
   After any OpenClaw update, `git diff` to see if files were overwritten.

2. **Disable bootstrap file creation** for pre-seeded workspaces:
   ```json5
   agents: { defaults: { createBootstrapFiles: false } }
   ```
   This tells OpenClaw not to recreate missing or overwrite existing workspace files.

3. **After every `openclaw update`:** check your workspace files before restarting
   the gateway. A quick `git status` in each workspace will show if anything changed.

4. **Keep backups outside the workspace:** store canonical copies of your workspace
   files in a separate repo or backup location that OpenClaw can't touch.

## Monitoring

- `/usage full` — per-turn token breakdown
- `/status` — session model, context usage, estimated cost
- Check OpenRouter dashboard for per-model spend
- Watch for M2.5 or Flash-Lite tool-use issues in early testing
- If any model misbehaves, fallback to Sonnet kicks in automatically
