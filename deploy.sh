#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
# OpenClaw Crew — Deployment Bootstrap
# Run this ONCE on a fresh machine before starting the gateway.
# Installs all tool prerequisites, creates workspace structure,
# and verifies the environment is ready.
# ═══════════════════════════════════════════════════════════

echo "🦞 OpenClaw Crew — Deployment Bootstrap"
echo "========================================"
echo ""

# ─── Flags ───────────────────────────────────────────────
FRESH=false
for arg in "$@"; do
  case "$arg" in
    --fresh) FRESH=true ;;
    --help|-h)
      echo "Usage: ./deploy.sh [--fresh]"
      echo ""
      echo "  --fresh   Back up and nuke existing ~/.openclaw/ before deploying."
      echo "            Backup saved to ~/openclaw-backup-<timestamp>.tar.gz"
      echo "            Use this to start completely clean."
      echo ""
      echo "  (no flag) Safe mode — installs missing tools and skips existing files."
      exit 0
      ;;
  esac
done

# ─── Fresh install: backup and nuke ─────────────────────
if [[ "$FRESH" == true ]]; then
  echo "⚠️  --fresh mode: will back up and remove existing OpenClaw setup"
  echo ""

  # Stop the gateway if running
  if systemctl --user is-active openclaw-gateway &>/dev/null; then
    echo "   Stopping openclaw-gateway service..."
    systemctl --user stop openclaw-gateway
  fi
  # Also try killing any running gateway process
  pkill -f "openclaw gateway" 2>/dev/null || true

  if [[ -d "$HOME/.openclaw" ]]; then
    BACKUP="$HOME/openclaw-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    echo "   📦 Backing up ~/.openclaw/ → $BACKUP"
    tar -czf "$BACKUP" -C "$HOME" .openclaw/
    echo "   🗑️  Removing ~/.openclaw/..."
    rm -rf "$HOME/.openclaw"
    echo "   ✅ Clean slate. Backup at: $BACKUP"
  else
    echo "   ℹ️  No existing ~/.openclaw/ found — nothing to nuke"
  fi
  echo ""
fi

# ─── Platform detection ──────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"
echo "Platform: $OS ($ARCH)"

if [[ "$OS" == "Darwin" ]]; then
  PKG_MGR="brew"
  if ! command -v brew &>/dev/null; then
    echo "❌ Homebrew not found. Install it first: https://brew.sh"
    exit 1
  fi
elif [[ "$OS" == "Linux" ]]; then
  PKG_MGR="apt"
  if ! command -v apt-get &>/dev/null; then
    echo "⚠️  apt not found — adjust install commands for your distro"
  fi
else
  echo "❌ Unsupported OS: $OS"
  exit 1
fi

# ─── 1. Node.js (OpenClaw runtime) ──────────────────────
echo ""
echo "1️⃣  Checking Node.js..."
if command -v node &>/dev/null; then
  NODE_VER=$(node -v)
  echo "   ✅ Node.js $NODE_VER"
else
  echo "   ❌ Node.js not found — installing..."
  if [[ "$PKG_MGR" == "brew" ]]; then
    brew install node@22
  else
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
  fi
fi

# ─── 2. OpenClaw itself ─────────────────────────────────
echo ""
echo "2️⃣  Checking OpenClaw..."
if command -v openclaw &>/dev/null; then
  OC_VER=$(openclaw --version 2>/dev/null || echo "unknown")
  if [[ "$FRESH" == true ]]; then
    echo "   🔄 Reinstalling OpenClaw (--fresh mode)..."
    npm uninstall -g openclaw 2>/dev/null
    npm install -g openclaw
    OC_VER=$(openclaw --version 2>/dev/null || echo "unknown")
    echo "   ✅ OpenClaw $OC_VER (fresh install)"
  else
    echo "   ✅ OpenClaw $OC_VER"
    echo "   ℹ️  Run 'npm update -g openclaw' if you want the latest version"
  fi
else
  echo "   📦 Installing OpenClaw..."
  npm install -g openclaw
fi

# ─── 3. Docker (for Qdrant memory backend) ──────────────
echo ""
echo "3️⃣  Checking Docker..."
if command -v docker &>/dev/null; then
  echo "   ✅ Docker $(docker --version | grep -oP '\d+\.\d+\.\d+')"
else
  echo "   📦 Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  echo "   ✅ Docker installed"
  echo "   ⚠️  You may need to log out and back in for docker group to apply"
fi

# ─── 4. Qdrant container (memory vector store) ──────────
echo ""
echo "4️⃣  Checking Qdrant..."
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "memory-qdrant"; then
  echo "   ✅ Qdrant container running"
elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "memory-qdrant"; then
  echo "   🔄 Starting existing Qdrant container..."
  docker start memory-qdrant
else
  echo "   📦 Starting Qdrant container..."
  docker run -d \
    --name memory-qdrant \
    --restart unless-stopped \
    -p 127.0.0.1:6333:6333 \
    -p 127.0.0.1:6334:6334 \
    -v qdrant-data:/qdrant/storage \
    qdrant/qdrant:latest
  echo "   ✅ Qdrant started (localhost:6333, not exposed to network)"
fi

# ─── 5. memory-qdrant CLI (agent memory skill) ──────────
echo ""
echo "5️⃣  Checking memory-qdrant CLI..."
if command -v memory &>/dev/null; then
  echo "   ✅ memory CLI found"
else
  echo "   📦 Installing memory-qdrant..."
  # Install from local path if available, otherwise from pip
  if [[ -d "$SCRIPT_DIR/memory-qdrant" ]]; then
    pip install "$SCRIPT_DIR/memory-qdrant" --break-system-packages 2>/dev/null \
      || pip install "$SCRIPT_DIR/memory-qdrant"
  else
    pip install memory-qdrant --break-system-packages 2>/dev/null \
      || pip install memory-qdrant
    # If package doesn't exist yet (skill not built), note it
    if ! command -v memory &>/dev/null; then
      echo "   ⚠️  memory-qdrant not yet published — build it first with Claude Code"
      echo "   See MEMORY-SKILL-SPEC.md for the full build spec"
    fi
  fi
fi

# Initialize collections if memory CLI is available and Qdrant is running
if command -v memory &>/dev/null; then
  if curl -sf http://localhost:6333/healthz &>/dev/null; then
    memory init 2>/dev/null && echo "   ✅ Qdrant collections initialized" \
      || echo "   ℹ️  Collections may already exist"
  fi
fi

# ─── 6. GOG (Google Workspace CLI — for Brand) ──────────
echo ""
echo "6️⃣  Checking gog (Google Workspace CLI)..."
if command -v gog &>/dev/null; then
  echo "   ✅ gog found"
else
  echo "   📦 Installing gog..."
  if [[ "$PKG_MGR" == "brew" ]]; then
    # Go is a prerequisite
    command -v go &>/dev/null || brew install go
    git clone https://github.com/steipete/gogcli.git /tmp/gogcli
    cd /tmp/gogcli && make build
    sudo cp bin/gog /usr/local/bin/
    cd - &>/dev/null
    rm -rf /tmp/gogcli
  else
    sudo snap install go --classic 2>/dev/null || sudo apt-get install -y golang
    git clone https://github.com/steipete/gogcli.git /tmp/gogcli
    cd /tmp/gogcli && make build
    sudo cp bin/gog /usr/local/bin/
    cd - &>/dev/null
    rm -rf /tmp/gogcli
  fi
  echo "   ⚠️  gog installed but needs auth setup:"
  echo "   Run: gog auth credentials ~/client_secret.json"
  echo "   Then: gog auth add <your-email> --services gmail,calendar,drive,contacts --manual"
fi

# ─── 7. Tailscale (secure remote access) ────────────────
echo ""
echo "7️⃣  Checking Tailscale..."
if command -v tailscale &>/dev/null; then
  TS_STATUS=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
  echo "   ✅ Tailscale installed (state: $TS_STATUS)"
else
  echo "   📦 Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  echo "   ✅ Tailscale installed"
  echo ""
  echo "   ⚠️  Tailscale needs authentication. Run:"
  echo "   sudo tailscale up"
  echo "   (This will print a URL — open it in your browser to log in)"
fi

# ─── 8. UFW firewall (lock SSH + gateway to Tailscale) ──
echo ""
echo "8️⃣  Configuring firewall..."
if command -v ufw &>/dev/null; then
  # Check if UFW is active
  UFW_STATUS=$(sudo ufw status 2>/dev/null | head -1 || echo "unknown")
  echo "   Current UFW status: $UFW_STATUS"

  # Check if Tailscale interface exists
  if ip link show tailscale0 &>/dev/null; then
    echo "   Tailscale interface detected — configuring firewall rules..."

    # Allow SSH only over Tailscale
    sudo ufw allow in on tailscale0 to any port 22 comment "SSH via Tailscale only"
    # Allow OpenClaw gateway only over Tailscale
    sudo ufw allow in on tailscale0 to any port 18789 comment "OpenClaw UI via Tailscale only"
    # Allow Tailscale's own UDP traffic (for NAT traversal)
    sudo ufw allow 41641/udp comment "Tailscale direct connections"
    # Block SSH from all other interfaces
    sudo ufw deny 22 comment "Block SSH from non-Tailscale"
    # Block OpenClaw gateway from all other interfaces
    sudo ufw deny 18789 comment "Block OpenClaw UI from non-Tailscale"

    # Enable UFW if not already active
    if [[ "$UFW_STATUS" != *"active"* ]]; then
      echo "   Enabling UFW (default deny incoming, allow outgoing)..."
      sudo ufw default deny incoming
      sudo ufw default allow outgoing
      echo "y" | sudo ufw enable
    fi

    echo "   ✅ Firewall configured: SSH + OpenClaw restricted to Tailscale"
    echo ""
    echo "   Active rules:"
    sudo ufw status numbered 2>/dev/null | head -20
  else
    echo "   ⚠️  Tailscale interface not found — run 'sudo tailscale up' first"
    echo "   Firewall configuration skipped (will configure on next run)"
  fi
else
  echo "   📦 Installing UFW..."
  sudo apt-get install -y ufw
  echo "   ⚠️  UFW installed but not configured — run deploy.sh again after Tailscale is connected"
fi

# ─── 9. Create workspace directories ────────────────────
echo ""
echo "9️⃣  Creating workspace structure..."
mkdir -p ~/.openclaw/workspace-cooper
mkdir -p ~/.openclaw/workspace-tars
mkdir -p ~/.openclaw/workspace-brand
mkdir -p ~/.openclaw/workspace-murph
mkdir -p ~/.openclaw/skills-shared
echo "   ✅ Workspaces created"

# ─── 10. Copy workspace files (if provided) ──────────────
echo ""
echo "🔟  Workspace files..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

copy_if_missing() {
  local src="$1" dst="$2"
  if [[ -f "$dst" ]]; then
    echo "   ⏭️  $dst already exists — skipping (won't overwrite)"
  elif [[ -f "$src" ]]; then
    cp "$src" "$dst"
    echo "   ✅ Copied $(basename "$dst")"
  else
    echo "   ⚠️  Source not found: $src"
  fi
}

# Cooper
for f in AGENTS.md SOUL.md IDENTITY.md USER.md TOOLS.md HEARTBEAT.md tasks.json; do
  copy_if_missing "$SCRIPT_DIR/workspace-cooper/$f" "$HOME/.openclaw/workspace-cooper/$f"
done

# Sub-agents (AGENTS.md + TOOLS.md only)
for agent in tars brand murph; do
  for f in AGENTS.md TOOLS.md; do
    copy_if_missing "$SCRIPT_DIR/workspace-$agent/$f" "$HOME/.openclaw/workspace-$agent/$f"
  done
done

# Config
if [[ -f "$HOME/.openclaw/openclaw.json" ]]; then
  echo "   ⏭️  openclaw.json already exists — skipping"
  echo "   ℹ️  Merge changes manually from $SCRIPT_DIR/openclaw.json5"
else
  if [[ -f "$SCRIPT_DIR/openclaw.json5" ]]; then
    cp "$SCRIPT_DIR/openclaw.json5" "$HOME/.openclaw/openclaw.json"
    echo "   ✅ Copied openclaw.json"
  fi
fi

# ─── 11. Git-track workspaces (overwrite protection) ─────
echo ""
echo "1️⃣1️⃣  Initializing git in workspaces..."
for ws in workspace-cooper workspace-tars workspace-brand workspace-murph; do
  ws_path="$HOME/.openclaw/$ws"
  if [[ -d "$ws_path/.git" ]]; then
    echo "   ⏭️  $ws already git-tracked"
  else
    cd "$ws_path"
    git init -q
    git add -A
    git commit -q -m "Initial workspace setup" 2>/dev/null || true
    echo "   ✅ $ws git-initialized"
  fi
done

# ─── 12. Secrets setup ───────────────────────────────────
echo ""
echo "1️⃣2️⃣  Secrets setup..."
ENV_FILE="$HOME/.openclaw/.env"
if [[ -f "$ENV_FILE" ]]; then
  echo "   ⏭️  .env already exists — skipping"
else
  if [[ -f "$SCRIPT_DIR/.env.example" ]]; then
    cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "   ✅ .env created from template (chmod 600)"
    echo "   ⚠️  EDIT $ENV_FILE with your real secrets!"
  else
    echo "   ⚠️  No .env.example found — create $ENV_FILE manually"
  fi
fi

# Copy .gitignore to ~/.openclaw/ root
if [[ -f "$SCRIPT_DIR/.gitignore" ]]; then
  cp "$SCRIPT_DIR/.gitignore" "$HOME/.openclaw/.gitignore"
  echo "   ✅ .gitignore copied to ~/.openclaw/"
fi

# Lock down file permissions
chmod 600 "$HOME/.openclaw/openclaw.json" 2>/dev/null || true
chmod 700 "$HOME/.openclaw" 2>/dev/null || true
echo "   ✅ File permissions hardened"

# ─── 13. Systemd service with EnvironmentFile ────────────
echo ""
echo "1️⃣3️⃣  Systemd service..."
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/openclaw-gateway.service"
if [[ -f "$SERVICE_FILE" ]]; then
  echo "   ⏭️  Service file already exists"
else
  mkdir -p "$SERVICE_DIR"
  cat > "$SERVICE_FILE" << SERVICEEOF
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
EnvironmentFile=$HOME/.openclaw/.env
ExecStart=$(command -v openclaw 2>/dev/null || echo "/usr/bin/openclaw") gateway
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
SERVICEEOF
  systemctl --user daemon-reload
  echo "   ✅ Systemd service created"
  echo "   Start with: systemctl --user enable --now openclaw-gateway"
fi

# ─── 14. Verify environment ─────────────────────────────
echo ""
echo "1️⃣4️⃣  Verification..."
echo "   ─────────────────────────────────────"
CHECKS_PASSED=0
CHECKS_TOTAL=0

check() {
  local name="$1" cmd="$2"
  CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
  if eval "$cmd" &>/dev/null; then
    echo "   ✅ $name"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
  else
    echo "   ❌ $name"
  fi
}

check "Node.js" "command -v node"
check "OpenClaw" "command -v openclaw"
check "Docker" "command -v docker"
check "Qdrant running" "curl -sf http://localhost:6333/healthz"
check "memory CLI" "command -v memory"
check "gog (Google)" "command -v gog"
check "git" "command -v git"
check "Tailscale installed" "command -v tailscale"
check "Tailscale connected" "tailscale status &>/dev/null"
check "UFW active" "sudo ufw status 2>/dev/null | grep -q 'Status: active'"
check "SSH restricted to Tailscale" "sudo ufw status 2>/dev/null | grep -q 'tailscale0.*22'"
check "Cooper workspace" "test -f ~/.openclaw/workspace-cooper/AGENTS.md"
check "TARS workspace" "test -f ~/.openclaw/workspace-tars/AGENTS.md"
check "Brand workspace" "test -f ~/.openclaw/workspace-brand/AGENTS.md"
check "Murph workspace" "test -f ~/.openclaw/workspace-murph/AGENTS.md"
check "Config exists" "test -f ~/.openclaw/openclaw.json"
check ".env exists" "test -f ~/.openclaw/.env"
check ".env permissions (600)" "test \$(stat -c '%a' ~/.openclaw/.env 2>/dev/null || echo 000) = 600"
check ".gitignore exists" "test -f ~/.openclaw/.gitignore"

echo "   ─────────────────────────────────────"
echo "   $CHECKS_PASSED / $CHECKS_TOTAL checks passed"

# ─── 15. Remaining manual steps ─────────────────────────
echo ""
echo "1️⃣5️⃣  Manual steps remaining:"
echo "   □ If Tailscale not yet connected: sudo tailscale up"
echo "   □ Install Tailscale on your laptop/phone (same account)"
echo "   □ Edit ~/.openclaw/.env with your real API keys and tokens"
echo "   □ Update USER.md with your name, timezone, preferences"
echo "   □ If using Gmail/Calendar: run gog auth setup"
echo "   □ Configure your Telegram/WhatsApp channel"
echo ""
echo "   Then:"
echo "   systemctl --user enable --now openclaw-gateway"
echo ""
echo "   Connect remotely:"
echo "   ssh $(whoami)@$(tailscale ip -4 2>/dev/null || echo '<tailscale-ip>')"
echo "   OpenClaw UI: http://$(tailscale ip -4 2>/dev/null || echo '<tailscale-ip>'):18789"
echo ""
echo "🦞 Done! Your crew is ready to deploy."
