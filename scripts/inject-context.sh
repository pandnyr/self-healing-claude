#!/usr/bin/env bash
# Self-Healing: Context injection at session start
# Called by SessionStart hook
# Features: time-based decay, cross-project learning, severity-aware ordering,
#   stack trace display, multi-solution system

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

if [ ! -f "$ERRORS_FILE" ] && [ ! -f "$PROJECT_CONTEXT_FILE" ]; then
  exit 0
fi

TOTAL_ERRORS=0
if [ -f "$ERRORS_FILE" ]; then
  TOTAL_ERRORS=$(wc -l < "$ERRORS_FILE" | tr -d ' ')
fi

if [ "$TOTAL_ERRORS" -eq 0 ] && [ ! -f "$PROJECT_CONTEXT_FILE" ]; then
  exit 0
fi

# ============================================================
# TIME-BASED DECAY: 30-day window
# ============================================================

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

severity_rank() {
  case "$1" in
    critical) echo "1" ;;
    high)     echo "2" ;;
    medium)   echo "3" ;;
    low)      echo "4" ;;
    *)        echo "5" ;;
  esac
}

echo ""
echo "[Self-Healing Context]"

# ============================================================
# PROJECT-SPECIFIC CONTEXT (time-decay + severity-aware)
# ============================================================

if [ -f "$PROJECT_CONTEXT_FILE" ]; then
  PROJECT_ERRORS=$(wc -l < "$PROJECT_CONTEXT_FILE" | tr -d ' ')

  if [ "$PROJECT_ERRORS" -gt 0 ]; then
    echo "Errors encountered in past sessions for this project ($PROJECT_DIR):"
    echo ""

    RECENT_LINES=$(tail -15 "$PROJECT_CONTEXT_FILE")

    TEMP_SORTED=$(mktemp)
    trap 'rm -f "$TEMP_SORTED"' EXIT

    while IFS= read -r line; do
      [ -z "$line" ] && continue

      TS=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null)
      SEVERITY=$(echo "$line" | jq -r '.severity // "medium"' 2>/dev/null)
      FIXED=$(echo "$line" | jq -r '.fixed // false' 2>/dev/null)

      if [ -n "$TS" ] && [ "$FIXED" = "true" ]; then
        ENTRY_EPOCH=$(get_epoch "$TS")
        if [ "$ENTRY_EPOCH" -gt 0 ] && [ "$ENTRY_EPOCH" -lt "$CUTOFF_EPOCH" ]; then
          continue
        fi
      fi

      RANK=$(severity_rank "$SEVERITY")
      echo "${RANK}|${line}" >> "$TEMP_SORTED"
    done <<< "$RECENT_LINES"

    IDX=1
    if [ -f "$TEMP_SORTED" ] && [ -s "$TEMP_SORTED" ]; then
      sort -t'|' -k1,1n "$TEMP_SORTED" | head -10 | while IFS='|' read -r _rank entry; do
        COMMAND=$(echo "$entry" | jq -r '.command // "?"' 2>/dev/null)
        ERROR_SNIPPET=$(echo "$entry" | jq -r '.error_snippet // "?"' 2>/dev/null | head -1 | head -c 120)
        ERROR_CAT=$(echo "$entry" | jq -r '.error_category // "?"' 2>/dev/null)
        SUB_CAT=$(echo "$entry" | jq -r '.error_sub_category // ""' 2>/dev/null)
        FRAMEWORK=$(echo "$entry" | jq -r '.framework // ""' 2>/dev/null)
        SEVERITY=$(echo "$entry" | jq -r '.severity // "medium"' 2>/dev/null)
        FIXED=$(echo "$entry" | jq -r '.fixed // false' 2>/dev/null)
        FIX_DESC=$(echo "$entry" | jq -r '.fix_description // ""' 2>/dev/null)

        if [ "$FIXED" = "true" ]; then
          FIX_STATUS="RESOLVED"
        else
          FIX_STATUS="UNRESOLVED"
        fi

        case "$SEVERITY" in
          critical) SEV_ICON="[!!!]" ;;
          high)     SEV_ICON="[!!]" ;;
          medium)   SEV_ICON="[!]" ;;
          *)        SEV_ICON="[-]" ;;
        esac

        FW_INFO=""
        [ -n "$FRAMEWORK" ] && FW_INFO=" (${FRAMEWORK})"

        SC_INFO=""
        [ -n "$SUB_CAT" ] && SC_INFO="/${SUB_CAT}"

        STACK_LOCS=$(echo "$entry" | jq -r '.stack_locations[]? // empty' 2>/dev/null | head -2 | tr '\n' ', ' | sed 's/, $//')
        STACK_INFO=""
        [ -n "$STACK_LOCS" ] && STACK_INFO=" @ ${STACK_LOCS}"

        echo "${IDX}. ${SEV_ICON} [${ERROR_CAT}${SC_INFO}]${FW_INFO} \`${COMMAND}\`${STACK_INFO} -> ${ERROR_SNIPPET} (${FIX_STATUS})"

        if [ "$FIXED" = "true" ] && [ -n "$FIX_DESC" ] && [ "$FIX_DESC" != "null" ]; then
          echo "   Fix: ${FIX_DESC}" | head -c 200
          echo ""

          if [ -f "$FIXES_FILE" ] && [ -n "$ERROR_CAT" ] && [ -n "$SUB_CAT" ]; then
            ALT_FIXES=$(jq -r --arg cat "$ERROR_CAT" --arg sub "$SUB_CAT" --arg desc "$FIX_DESC" \
              'select(.error_category == $cat and .error_sub_category == $sub and .fix_description != $desc and .fix_description != "(aradaki islemler kaydedilmedi)" and .fix_description != null and .fix_description != "") | .fix_description' \
              "$FIXES_FILE" 2>/dev/null | sort -u | head -3)
            if [ -n "$ALT_FIXES" ]; then
              echo "   Alternative solutions:"
              echo "$ALT_FIXES" | while IFS= read -r alt; do
                echo "     -> ${alt}" | head -c 180
                echo ""
              done
            fi
          fi
        elif [ "$FIXED" = "false" ] || [ "$FIX_STATUS" = "UNRESOLVED" ]; then
          if [ -f "$FIXES_FILE" ] && [ -n "$ERROR_CAT" ] && [ -n "$SUB_CAT" ]; then
            KNOWN_FIXES=$(jq -r --arg cat "$ERROR_CAT" --arg sub "$SUB_CAT" \
              'select(.error_category == $cat and .error_sub_category == $sub and .fix_description != "(aradaki islemler kaydedilmedi)" and .fix_description != null and .fix_description != "") | .fix_description' \
              "$FIXES_FILE" 2>/dev/null | sort -u | head -3)
            if [ -n "$KNOWN_FIXES" ]; then
              FIX_COUNT=$(echo "$KNOWN_FIXES" | wc -l | tr -d ' ')
              echo "   Known ${FIX_COUNT} solution(s):"
              echo "$KNOWN_FIXES" | while IFS= read -r kf; do
                echo "     -> ${kf}" | head -c 180
                echo ""
              done
            fi
          fi
        fi

        IDX=$((IDX + 1))
      done
    fi

    echo ""

    echo "Error distribution:"
    if command -v jq >/dev/null 2>&1; then
      jq -r '[.error_category, .severity] | join(" ")' "$PROJECT_CONTEXT_FILE" 2>/dev/null | \
        sort | uniq -c | sort -rn | head -5 | while read -r count cat sev; do
          echo "  - ${cat} (${sev}): ${count}x"
        done
    fi

    FIXED_COUNT=$(jq -r 'select(.fixed == true)' "$PROJECT_CONTEXT_FILE" 2>/dev/null | jq -s 'length' 2>/dev/null || echo "0")
    if [ "$PROJECT_ERRORS" -gt 0 ]; then
      FIX_RATE=$(echo "scale=0; $FIXED_COUNT * 100 / $PROJECT_ERRORS" | bc 2>/dev/null || echo "?")
      echo "  Fix rate: ${FIXED_COUNT}/${PROJECT_ERRORS} (${FIX_RATE}%)"
    fi

    FW_DIST=$(jq -r 'select(.framework != "" and .framework != null) | .framework' "$PROJECT_CONTEXT_FILE" 2>/dev/null | sort | uniq -c | sort -rn | head -3)
    if [ -n "$FW_DIST" ]; then
      echo "  Framework distribution:"
      echo "$FW_DIST" | while read -r count fw; do
        [ -n "$fw" ] && echo "    - ${fw}: ${count} errors"
      done
    fi

    echo ""
  fi
fi

# ============================================================
# UNRESOLVED RECURRING ERRORS (severity-aware)
# ============================================================

if [ -f "$ERRORS_FILE" ] && [ "$TOTAL_ERRORS" -gt 2 ]; then
  CRITICAL_UNFIXED=$(jq -r 'select(.fixed == false and (.severity == "critical" or .severity == "high")) | .error_snippet' "$ERRORS_FILE" 2>/dev/null | \
    head -c 80 | sort | uniq -c | sort -rn | head -3)

  if [ -n "$CRITICAL_UNFIXED" ]; then
    echo "PRIORITY - unresolved critical/high errors:"
    echo "$CRITICAL_UNFIXED" | while read -r count snippet; do
      if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
        echo "  - (${count}x) ${snippet}"
      fi
    done
    echo ""
  fi

  REPEATING=$(jq -r 'select(.fixed == false) | .error_snippet' "$ERRORS_FILE" 2>/dev/null | \
    head -c 80 | sort | uniq -c | sort -rn | head -3)

  if [ -n "$REPEATING" ]; then
    echo "Warning - recurring unresolved errors:"
    echo "$REPEATING" | while read -r count snippet; do
      if [ "$count" -gt 1 ] 2>/dev/null; then
        echo "  - (${count}x) ${snippet}"
      fi
    done
    echo ""
  fi
fi

# ============================================================
# CROSS-PROJECT LEARNING
# ============================================================

if [ -d "$CONTEXTS_DIR" ]; then
  OTHER_PROJECTS=$(ls "$CONTEXTS_DIR"/*.jsonl 2>/dev/null | grep -v "${PROJECT_HASH}.jsonl" | head -20 || true)

  if [ -n "$OTHER_PROJECTS" ]; then
    CROSS_PATTERNS=$(mktemp)
    trap 'rm -f "$CROSS_PATTERNS" "$TEMP_SORTED"' EXIT

    CROSS_FIX_SAMPLES=$(mktemp)
    for ctx_file in $OTHER_PROJECTS; do
      jq -r 'select(.fixed == true) | [.error_category, .error_sub_category] | join("|")' "$ctx_file" 2>/dev/null >> "$CROSS_PATTERNS" || true
      jq -r 'select(.fixed == true and .fix_description != null and .fix_description != "") | [.error_category, .error_sub_category, .fix_description] | join("|")' "$ctx_file" 2>/dev/null >> "$CROSS_FIX_SAMPLES" || true
    done

    if [ -s "$CROSS_PATTERNS" ]; then
      TOP_CROSS=$(sort "$CROSS_PATTERNS" | uniq -c | sort -rn | head -5)

      HAS_INSIGHT=false
      while read -r count pattern_line; do
        [ -z "$count" ] && continue
        [ "$count" -lt 2 ] 2>/dev/null && continue

        CAT=$(echo "$pattern_line" | cut -d'|' -f1)
        SUB=$(echo "$pattern_line" | cut -d'|' -f2)

        [ -z "$CAT" ] && continue

        if [ "$HAS_INSIGHT" = "false" ]; then
          echo "Lessons learned from other projects:"
          HAS_INSIGHT=true
        fi

        SUB_INFO=""
        [ -n "$SUB" ] && SUB_INFO="/${SUB}"

        SAMPLE_FIX=""
        if [ -s "$CROSS_FIX_SAMPLES" ]; then
          SAMPLE_FIX=$(grep "^${CAT}|${SUB}|" "$CROSS_FIX_SAMPLES" 2>/dev/null | head -1 | cut -d'|' -f3- | head -c 150)
        fi

        if [ -n "$SAMPLE_FIX" ] && [ "$SAMPLE_FIX" != "(aradaki islemler kaydedilmedi)" ]; then
          echo "  - [${CAT}${SUB_INFO}] Resolved in ${count} projects -> Example: ${SAMPLE_FIX}"
        else
          echo "  - [${CAT}${SUB_INFO}] Resolved in ${count} projects"
        fi
      done <<< "$TOP_CROSS"

      [ "$HAS_INSIGHT" = "true" ] && echo ""
    fi

    rm -f "$CROSS_FIX_SAMPLES"
    rm -f "$CROSS_PATTERNS"
  fi
fi

# ============================================================
# WEEKLY TREND
# ============================================================

if [ -f "$PROJECT_CONTEXT_FILE" ]; then
  if date -v-7d +%s >/dev/null 2>&1; then
    WEEK_AGO_EPOCH=$(date -v-7d +%s)
    TWO_WEEKS_AGO_EPOCH=$(date -v-14d +%s)
  else
    WEEK_AGO_EPOCH=$(date -d '7 days ago' +%s 2>/dev/null || echo "0")
    TWO_WEEKS_AGO_EPOCH=$(date -d '14 days ago' +%s 2>/dev/null || echo "0")
  fi

  if [ "$WEEK_AGO_EPOCH" -gt 0 ] && [ "$TWO_WEEKS_AGO_EPOCH" -gt 0 ]; then
    THIS_WEEK=0
    LAST_WEEK=0
    THIS_WEEK_FIXED=0
    LAST_WEEK_FIXED=0

    while IFS= read -r tline; do
      [ -z "$tline" ] && continue
      T_TS=$(echo "$tline" | jq -r '.ts // ""' 2>/dev/null)
      T_FIXED=$(echo "$tline" | jq -r '.fixed // false' 2>/dev/null)
      [ -z "$T_TS" ] && continue

      T_EPOCH=$(get_epoch "$T_TS")
      [ "$T_EPOCH" -eq 0 ] 2>/dev/null && continue

      if [ "$T_EPOCH" -ge "$WEEK_AGO_EPOCH" ]; then
        THIS_WEEK=$((THIS_WEEK + 1))
        [ "$T_FIXED" = "true" ] && THIS_WEEK_FIXED=$((THIS_WEEK_FIXED + 1))
      elif [ "$T_EPOCH" -ge "$TWO_WEEKS_AGO_EPOCH" ]; then
        LAST_WEEK=$((LAST_WEEK + 1))
        [ "$T_FIXED" = "true" ] && LAST_WEEK_FIXED=$((LAST_WEEK_FIXED + 1))
      fi
    done < "$PROJECT_CONTEXT_FILE"

    if [ "$THIS_WEEK" -gt 0 ] || [ "$LAST_WEEK" -gt 0 ]; then
      echo "Weekly trend:"
      if [ "$LAST_WEEK" -gt 0 ]; then
        CHANGE=$((THIS_WEEK - LAST_WEEK))
        if [ "$CHANGE" -lt 0 ]; then
          ABS_CHANGE=$(( -1 * CHANGE ))
          PCT=$(echo "scale=0; $ABS_CHANGE * 100 / $LAST_WEEK" | bc 2>/dev/null || echo "?")
          echo "  This week: ${THIS_WEEK} errors, last week: ${LAST_WEEK} errors (${PCT}% decrease - improving)"
        elif [ "$CHANGE" -gt 0 ]; then
          PCT=$(echo "scale=0; $CHANGE * 100 / $LAST_WEEK" | bc 2>/dev/null || echo "?")
          echo "  This week: ${THIS_WEEK} errors, last week: ${LAST_WEEK} errors (${PCT}% increase - attention needed)"
        else
          echo "  This week: ${THIS_WEEK} errors, last week: ${LAST_WEEK} errors (no change)"
        fi
      else
        echo "  This week: ${THIS_WEEK} errors (no data for last week)"
      fi

      if [ "$THIS_WEEK" -gt 0 ]; then
        THIS_FIX_PCT=$(echo "scale=0; $THIS_WEEK_FIXED * 100 / $THIS_WEEK" | bc 2>/dev/null || echo "?")
        echo "  This week's fix rate: ${THIS_FIX_PCT}%"
      fi
      echo ""
    fi
  fi
fi

# ============================================================
# PATTERNS.JSON INSIGHTS
# ============================================================

if [ -f "$PATTERNS_FILE" ]; then
  INSIGHTS=$(jq -r '.global_insights[]? // empty' "$PATTERNS_FILE" 2>/dev/null | head -5)
  if [ -n "$INSIGHTS" ]; then
    echo "Learned lessons (pattern analysis):"
    echo "$INSIGHTS" | while IFS= read -r insight; do
      echo "  - $insight"
    done
    echo ""
  fi

  FW_PATTERNS=$(jq -r '.framework_insights[]? // empty' "$PATTERNS_FILE" 2>/dev/null | head -3)
  if [ -n "$FW_PATTERNS" ]; then
    echo "Framework-specific suggestions:"
    echo "$FW_PATTERNS" | while IFS= read -r fp; do
      echo "  - $fp"
    done
    echo ""
  fi
fi

echo "[/Self-Healing Context]"
echo ""

exit 0
