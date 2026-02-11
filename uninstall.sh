#!/usr/bin/env bash
# Self-Healing Claude - Uninstall Script
# https://github.com/pandnyr/self-healing-claude

set -euo pipefail

SKILL_DIR="$HOME/.claude/skills/self-healing"
DATA_DIR="$HOME/.claude/self-healing"
SETTINGS_FILE="$HOME/.claude/settings.json"

PURGE=false
if [ "${1:-}" = "--purge" ]; then
  PURGE=true
fi

echo "================================================"
echo "  Self-Healing Claude - Uninstaller"
echo "================================================"
echo ""

if [ "$PURGE" = "true" ]; then
  echo "This will remove:"
  echo "  - Skill files ($SKILL_DIR)"
  echo "  - Hooks from settings.json"
  echo "  - ALL learned data ($DATA_DIR)"
  echo ""
else
  echo "This will remove:"
  echo "  - Skill files ($SKILL_DIR)"
  echo "  - Hooks from settings.json"
  echo ""
  echo "Learned data in $DATA_DIR will be preserved."
  echo "Use --purge to also remove learned data."
  echo ""
fi

read -r -p "Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Cancelled."
  exit 0
fi

# Remove hooks
if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null; then
  echo "[1/3] Removing hooks from settings.json..."
  UPDATED=$(cat "$SETTINGS_FILE" | jq '
    if .hooks then
      .hooks.PostToolUse = [.hooks.PostToolUse[]? | select(.command | contains("self-healing") | not)] |
      .hooks.SessionStart = [.hooks.SessionStart[]? | select(.command | contains("self-healing") | not)] |
      if (.hooks.PostToolUse | length) == 0 then del(.hooks.PostToolUse) else . end |
      if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end |
      if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
  ')
  echo "$UPDATED" | jq '.' > "$SETTINGS_FILE"
  echo "  Hooks removed"
else
  echo "[1/3] settings.json not found or jq not available, skipping"
fi

# Remove skill files
echo "[2/3] Removing skill files..."
if [ -d "$SKILL_DIR" ]; then
  rm -rf "$SKILL_DIR"
  echo "  Removed $SKILL_DIR"
else
  echo "  $SKILL_DIR not found, skipping"
fi

# Remove data (if --purge)
if [ "$PURGE" = "true" ]; then
  echo "[3/3] Removing learned data..."
  if [ -d "$DATA_DIR" ]; then
    rm -rf "$DATA_DIR"
    echo "  Removed $DATA_DIR"
  else
    echo "  $DATA_DIR not found, skipping"
  fi
else
  echo "[3/3] Keeping learned data in $DATA_DIR"
fi

echo ""
echo "================================================"
echo "  Uninstall complete!"
echo "================================================"
echo ""
