#!/usr/bin/env bash
# Self-Healing Claude - Installation Script
# https://github.com/pandnyr/self-healing-claude

set -euo pipefail

SKILL_DIR="$HOME/.claude/skills/self-healing"
DATA_DIR="$HOME/.claude/self-healing"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "================================================"
echo "  Self-Healing Claude - Installer"
echo "================================================"
echo ""

# 1. Dependency check
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed."
  echo ""
  echo "Install it with:"
  echo "  macOS:         brew install jq"
  echo "  Ubuntu/Debian: sudo apt install jq"
  echo "  Fedora:        sudo dnf install jq"
  exit 1
fi
echo "[1/5] Dependencies OK (jq found)"

# 2. Download/copy files
mkdir -p "$SKILL_DIR/scripts" "$DATA_DIR/project-contexts"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/skills/SKILL.md" ]; then
  echo "[2/5] Installing from local repository..."
  cp "$SCRIPT_DIR/skills/SKILL.md" "$SKILL_DIR/SKILL.md"
  cp "$SCRIPT_DIR/skills/error-patterns.md" "$SKILL_DIR/error-patterns.md"
  for script in capture-error.sh inject-context.sh analyze-patterns.sh preload.sh cleanup.sh; do
    cp "$SCRIPT_DIR/scripts/$script" "$SKILL_DIR/scripts/$script"
  done
else
  echo "[2/5] Downloading files from GitHub..."
  BASE_URL="https://raw.githubusercontent.com/pandnyr/self-healing-claude/main"
  curl -fsSL "$BASE_URL/skills/SKILL.md" -o "$SKILL_DIR/SKILL.md"
  curl -fsSL "$BASE_URL/skills/error-patterns.md" -o "$SKILL_DIR/error-patterns.md"
  for script in capture-error.sh inject-context.sh analyze-patterns.sh preload.sh cleanup.sh; do
    curl -fsSL "$BASE_URL/scripts/$script" -o "$SKILL_DIR/scripts/$script"
  done
fi

# 3. Set permissions
chmod +x "$SKILL_DIR/scripts/"*.sh
echo "[3/5] Permissions set"

# 4. Configure hooks
echo "[4/5] Configuring hooks..."
mkdir -p "$(dirname "$SETTINGS_FILE")"

if [ ! -f "$SETTINGS_FILE" ]; then
  echo '{}' > "$SETTINGS_FILE"
fi

if cat "$SETTINGS_FILE" | jq -e '.hooks.PostToolUse[]? | select(.command | contains("self-healing"))' &>/dev/null; then
  echo "  Hooks already configured, skipping..."
else
  MERGED=$(cat "$SETTINGS_FILE" | jq '{
    hooks: {
      PostToolUse: ((.hooks.PostToolUse // []) + [{"matcher": "Bash|Edit|Write", "command": "bash ~/.claude/skills/self-healing/scripts/capture-error.sh"}]),
      SessionStart: ((.hooks.SessionStart // []) + [{"command": "bash ~/.claude/skills/self-healing/scripts/inject-context.sh"}])
    }
  } * (del(.hooks) // {})')
  FINAL=$(cat "$SETTINGS_FILE" | jq --argjson merged "$MERGED" '. * $merged')
  echo "$FINAL" | jq '.' > "$SETTINGS_FILE"
  echo "  Hooks added to $SETTINGS_FILE"
fi

# 5. Preload
echo "[5/5] Running preload (30 error/fix pairs)..."
bash "$SKILL_DIR/scripts/preload.sh" 2>/dev/null || true

echo ""
echo "================================================"
echo "  Installation complete!"
echo "================================================"
echo ""
echo "Self-Healing Claude is now active. It will:"
echo "  - Capture errors automatically via hooks"
echo "  - Learn from your fixes"
echo "  - Inject learned context at session start"
echo ""
echo "Useful commands:"
echo "  Stats:    bash ~/.claude/skills/self-healing/scripts/cleanup.sh"
echo "  Cleanup:  bash ~/.claude/skills/self-healing/scripts/cleanup.sh --old"
echo "  Analyze:  bash ~/.claude/skills/self-healing/scripts/analyze-patterns.sh"
echo ""
