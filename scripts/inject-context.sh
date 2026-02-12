#!/usr/bin/env bash
# Self-Healing: Compact context injection at session start
# Called by SessionStart hook
# v3.0 - Minimized context footprint
#   - Compact mode: healthy projects get 1-line summary
#   - Project filter: no project errors = skip global noise
#   - Threshold: 0 unfixed = minimal output
#   - Summary mode: single line instead of detailed list

set -euo pipefail

DATA_DIR="$HOME/.claude/self-healing"

# Auto-preload: run preload.sh once if marker doesn't exist
if [ ! -f "$DATA_DIR/.preload_done" ]; then
  bash "$HOME/.claude/skills/self-healing/scripts/preload.sh" > /dev/null 2>&1 || true
fi

ERRORS_FILE="$DATA_DIR/errors.jsonl"
FIXES_FILE="$DATA_DIR/fixes.jsonl"
PATTERNS_FILE="$DATA_DIR/patterns.json"
CONTEXTS_DIR="$DATA_DIR/project-contexts"

if [ ! -d "$DATA_DIR" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROJECT_HASH=$(echo -n "$PROJECT_DIR" | shasum -a 256 | cut -c1-12)
PROJECT_CONTEXT_FILE="$CONTEXTS_DIR/${PROJECT_HASH}.jsonl"

# No data at all -> silent exit
if [ ! -f "$ERRORS_FILE" ] && [ ! -f "$PROJECT_CONTEXT_FILE" ]; then
  exit 0
fi

# ============================================================
# GATHER STATS
# ============================================================

PROJECT_ERRORS=0
PROJECT_FIXED=0
PROJECT_UNFIXED=0

if [ -f "$PROJECT_CONTEXT_FILE" ]; then
  PROJECT_ERRORS=$(wc -l < "$PROJECT_CONTEXT_FILE" | tr -d ' ')
  PROJECT_FIXED=$(jq -r 'select(.fixed == true)' "$PROJECT_CONTEXT_FILE" 2>/dev/null | jq -s 'length' 2>/dev/null || echo "0")
  PROJECT_UNFIXED=$((PROJECT_ERRORS - PROJECT_FIXED))
  [ "$PROJECT_UNFIXED" -lt 0 ] && PROJECT_UNFIXED=0
fi

GLOBAL_ERRORS=0
GLOBAL_UNFIXED=0
if [ -f "$ERRORS_FILE" ]; then
  GLOBAL_ERRORS=$(wc -l < "$ERRORS_FILE" | tr -d ' ')
  GLOBAL_UNFIXED=$(jq -r 'select(.fixed == false)' "$ERRORS_FILE" 2>/dev/null | jq -s 'length' 2>/dev/null || echo "0")
fi

# No errors anywhere -> silent exit
if [ "$GLOBAL_ERRORS" -eq 0 ] && [ "$PROJECT_ERRORS" -eq 0 ]; then
  exit 0
fi

# ============================================================
# DECISION: COMPACT vs DETAILED
# ============================================================
# Compact: 0 unfixed project errors -> 1-line summary
# Detailed: unfixed errors exist -> show them with solutions

echo ""
echo "[Self-Healing Context]"

if [ "$PROJECT_UNFIXED" -eq 0 ] && [ "$PROJECT_ERRORS" -gt 0 ]; then
  # ============================================================
  # COMPACT MODE: All project errors resolved
  # ============================================================
  FIX_RATE=$(echo "scale=0; $PROJECT_FIXED * 100 / $PROJECT_ERRORS" | bc 2>/dev/null || echo "100")
  echo "Proje sagligi: ${PROJECT_ERRORS} hata, %${FIX_RATE} fix, 0 acik sorun"

  # Only show framework insights as a one-liner if available
  if [ -f "$PATTERNS_FILE" ]; then
    FW_LINE=$(jq -r '.framework_insights[]? // empty' "$PATTERNS_FILE" 2>/dev/null | head -3 | tr '\n' ' | ' | sed 's/ | $//')
    [ -n "$FW_LINE" ] && echo "Oneriler: ${FW_LINE}"
  fi

  echo "[/Self-Healing Context]"
  echo ""
  exit 0
fi

if [ "$PROJECT_ERRORS" -eq 0 ] && [ "$GLOBAL_UNFIXED" -eq 0 ]; then
  # ============================================================
  # NO PROJECT DATA, GLOBAL ALL FIXED: minimal output
  # ============================================================
  echo "Bu projede kayitli hata yok. Global: ${GLOBAL_ERRORS} hata, hepsi cozulmus."
  echo "[/Self-Healing Context]"
  echo ""
  exit 0
fi

# ============================================================
# DETAILED MODE: Unfixed errors exist - show only what matters
# ============================================================

# Helper: macOS/GNU date compat
get_epoch() {
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null; then
    return
  elif date -d "$1" +%s 2>/dev/null; then
    return
  else
    echo "0"
  fi
}

NOW_EPOCH=$(date +%s)
DECAY_WINDOW=$((30 * 24 * 3600))
CUTOFF_EPOCH=$((NOW_EPOCH - DECAY_WINDOW))

# --- Show ONLY unfixed project errors (not all history) ---
if [ -f "$PROJECT_CONTEXT_FILE" ] && [ "$PROJECT_UNFIXED" -gt 0 ]; then
  echo "Acik sorunlar (${PROJECT_UNFIXED} cozulmemis):"
  echo ""

  # Extract only unfixed entries, sort by severity
  TEMP_SORTED=$(mktemp)
  trap 'rm -f "$TEMP_SORTED"' EXIT

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    FIXED=$(echo "$line" | jq -r '.fixed // false' 2>/dev/null)
    [ "$FIXED" = "true" ] && continue

    SEVERITY=$(echo "$line" | jq -r '.severity // "medium"' 2>/dev/null)
    case "$SEVERITY" in
      critical) RANK=1 ;; high) RANK=2 ;; medium) RANK=3 ;; *) RANK=4 ;;
    esac
    echo "${RANK}|${line}" >> "$TEMP_SORTED"
  done < "$PROJECT_CONTEXT_FILE"

  if [ -f "$TEMP_SORTED" ] && [ -s "$TEMP_SORTED" ]; then
    IDX=1
    sort -t'|' -k1,1n "$TEMP_SORTED" | head -7 | while IFS='|' read -r _rank entry; do
      COMMAND=$(echo "$entry" | jq -r '.command // "?"' 2>/dev/null)
      ERROR_SNIPPET=$(echo "$entry" | jq -r '.error_snippet // "?"' 2>/dev/null | head -1 | head -c 100)
      ERROR_CAT=$(echo "$entry" | jq -r '.error_category // "?"' 2>/dev/null)
      SUB_CAT=$(echo "$entry" | jq -r '.error_sub_category // ""' 2>/dev/null)
      FRAMEWORK=$(echo "$entry" | jq -r '.framework // ""' 2>/dev/null)
      SEVERITY=$(echo "$entry" | jq -r '.severity // "medium"' 2>/dev/null)

      case "$SEVERITY" in
        critical) SEV="[!!!]" ;; high) SEV="[!!]" ;; medium) SEV="[!]" ;; *) SEV="[-]" ;;
      esac

      FW="" ; [ -n "$FRAMEWORK" ] && FW=" (${FRAMEWORK})"
      SC="" ; [ -n "$SUB_CAT" ] && SC="/${SUB_CAT}"

      echo "${IDX}. ${SEV} [${ERROR_CAT}${SC}]${FW} \`${COMMAND}\` -> ${ERROR_SNIPPET}"

      # Show known fixes for this error type
      if [ -f "$FIXES_FILE" ] && [ -n "$SUB_CAT" ]; then
        KNOWN_FIX=$(jq -r --arg cat "$ERROR_CAT" --arg sub "$SUB_CAT" \
          'select(.error_category == $cat and .error_sub_category == $sub and .fix_description != "(aradaki islemler kaydedilmedi)" and .fix_description != null and .fix_description != "") | .fix_description' \
          "$FIXES_FILE" 2>/dev/null | sort -u | head -2)
        if [ -n "$KNOWN_FIX" ]; then
          echo "$KNOWN_FIX" | while IFS= read -r kf; do
            echo "   -> ${kf}" | head -c 150
          done
        fi
      fi

      IDX=$((IDX + 1))
    done
  fi

  echo ""

  # Compact stats: one line
  FIX_RATE=$(echo "scale=0; $PROJECT_FIXED * 100 / $PROJECT_ERRORS" | bc 2>/dev/null || echo "?")
  echo "Ozet: ${PROJECT_ERRORS} toplam, ${PROJECT_FIXED} cozulmus (%${FIX_RATE}), ${PROJECT_UNFIXED} acik"
  echo ""
fi

# --- Cross-project: only if we have unfixed errors and other projects solved same type ---
if [ -f "$PROJECT_CONTEXT_FILE" ] && [ "$PROJECT_UNFIXED" -gt 0 ] && [ -d "$CONTEXTS_DIR" ]; then
  # Get unfixed error categories from this project
  UNFIXED_CATS=$(jq -r 'select(.fixed == false) | [.error_category, .error_sub_category] | join("|")' "$PROJECT_CONTEXT_FILE" 2>/dev/null | sort -u)

  if [ -n "$UNFIXED_CATS" ]; then
    OTHER_PROJECTS=$(ls "$CONTEXTS_DIR"/*.jsonl 2>/dev/null | grep -v "${PROJECT_HASH}.jsonl" | head -10 || true)

    if [ -n "$OTHER_PROJECTS" ]; then
      CROSS_FIXES=$(mktemp)
      trap 'rm -f "$TEMP_SORTED" "$CROSS_FIXES"' EXIT

      for ctx_file in $OTHER_PROJECTS; do
        jq -r 'select(.fixed == true and .fix_description != null and .fix_description != "" and .fix_description != "(aradaki islemler kaydedilmedi)") | [.error_category, .error_sub_category, .fix_description] | join("|")' "$ctx_file" 2>/dev/null >> "$CROSS_FIXES" || true
      done

      if [ -s "$CROSS_FIXES" ]; then
        HAS_CROSS=false
        while IFS= read -r cat_pair; do
          CAT=$(echo "$cat_pair" | cut -d'|' -f1)
          SUB=$(echo "$cat_pair" | cut -d'|' -f2)
          MATCH=$(grep "^${CAT}|${SUB}|" "$CROSS_FIXES" 2>/dev/null | head -1 | cut -d'|' -f3- | head -c 120)
          if [ -n "$MATCH" ]; then
            [ "$HAS_CROSS" = "false" ] && echo "Diger projelerden bilinen cozumler:" && HAS_CROSS=true
            SC="" ; [ -n "$SUB" ] && SC="/${SUB}"
            echo "  - [${CAT}${SC}] -> ${MATCH}"
          fi
        done <<< "$UNFIXED_CATS"
        [ "$HAS_CROSS" = "true" ] && echo ""
      fi

      rm -f "$CROSS_FIXES"
    fi
  fi
fi

# --- Framework insights: only if relevant to unfixed errors ---
if [ -f "$PATTERNS_FILE" ] && [ "$PROJECT_UNFIXED" -gt 0 ]; then
  # Get frameworks from unfixed errors
  UNFIXED_FW=$(jq -r 'select(.fixed == false and .framework != "" and .framework != null) | .framework' "$PROJECT_CONTEXT_FILE" 2>/dev/null | sort -u | head -3)

  if [ -n "$UNFIXED_FW" ]; then
    FW_HINTS=$(jq -r '.framework_insights[]? // empty' "$PATTERNS_FILE" 2>/dev/null)
    if [ -n "$FW_HINTS" ]; then
      HAS_FW=false
      while IFS= read -r fw; do
        MATCH=$(echo "$FW_HINTS" | grep -i "$fw" | head -1)
        if [ -n "$MATCH" ]; then
          [ "$HAS_FW" = "false" ] && echo "Framework onerisi:" && HAS_FW=true
          echo "  - $MATCH"
        fi
      done <<< "$UNFIXED_FW"
      [ "$HAS_FW" = "true" ] && echo ""
    fi
  fi
fi

echo "[/Self-Healing Context]"
echo ""

exit 0
