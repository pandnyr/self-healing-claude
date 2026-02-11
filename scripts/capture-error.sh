#!/usr/bin/env bash
# Self-Healing: Error capture, fix detection, and intermediate operation tracking
# Called by PostToolUse hook
# Features: fix description, severity, smart categorization, framework detection,
#   data rotation, deduplication, auto-analysis, multi-solution tracking

set -euo pipefail

DATA_DIR="$HOME/.claude/self-healing"
ERRORS_FILE="$DATA_DIR/errors.jsonl"
FIXES_FILE="$DATA_DIR/fixes.jsonl"
CONTEXTS_DIR="$DATA_DIR/project-contexts"
LAST_ERROR_FILE="$DATA_DIR/.last-error"
PENDING_OPS_FILE="$DATA_DIR/.pending-ops"

MAX_ERRORS=500
MAX_PROJECT_ERRORS=200
AUTO_ANALYZE_INTERVAL=20

mkdir -p "$DATA_DIR" "$CONTEXTS_DIR"

# Read tool input from stdin
TOOL_INPUT=$(cat)

TOOL_NAME="${TOOL_NAME:-unknown}"
EXIT_CODE="${TOOL_EXIT_CODE:-0}"
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s)}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROJECT_HASH=$(echo -n "$PROJECT_DIR" | shasum -a 256 | cut -c1-12)
PROJECT_CONTEXT_FILE="$CONTEXTS_DIR/${PROJECT_HASH}.jsonl"

# ============================================================
# HELPER FUNCTIONS
# ============================================================

# Data rotation: clean old records when file exceeds max line limit
rotate_file() {
  local file="$1"
  local max_lines="$2"

  [ ! -f "$file" ] && return

  local current_lines
  current_lines=$(wc -l < "$file" | tr -d ' ')
  [ "$current_lines" -le "$max_lines" ] && return

  local keep_lines=$((max_lines * 3 / 4))
  local temp_file
  temp_file=$(mktemp)

  # Priority: preserve unfixed (fixed=false) records, trim old fixed ones
  {
    jq -c 'select(.fixed == false or .fixed == null)' "$file" 2>/dev/null
    jq -c 'select(.fixed == true)' "$file" 2>/dev/null | tail -$((keep_lines / 2))
  } > "$temp_file" 2>/dev/null || true

  local new_lines
  new_lines=$(wc -l < "$temp_file" | tr -d ' ')
  if [ "$new_lines" -gt "$max_lines" ]; then
    tail -"$keep_lines" "$temp_file" > "${temp_file}.2"
    mv "${temp_file}.2" "$temp_file"
  fi

  mv "$temp_file" "$file"
}

# Deduplication: check if same session+command already recorded
is_duplicate() {
  local cmd="$1"
  local snippet="$2"
  local session="$3"

  [ ! -f "$ERRORS_FILE" ] && return 1

  local match
  match=$(tail -5 "$ERRORS_FILE" | jq -r --arg s "$session" --arg c "$cmd" \
    'select(.session == $s and .command == $c) | .command' 2>/dev/null | head -1)

  [ -n "$match" ] && return 0
  return 1
}

# Auto-analysis trigger: every N errors
maybe_auto_analyze() {
  [ ! -f "$ERRORS_FILE" ] && return

  local total
  total=$(wc -l < "$ERRORS_FILE" | tr -d ' ')

  if [ $((total % AUTO_ANALYZE_INTERVAL)) -eq 0 ] && [ "$total" -gt 0 ]; then
    bash "$HOME/.claude/skills/self-healing/scripts/analyze-patterns.sh" > /dev/null 2>&1 &
  fi
}

# Smart categorization: detect category and framework from error snippet + command
classify_error() {
  local snippet="$1"
  local command="$2"
  local category="unknown"
  local framework=""
  local sub_category=""

  # -- Framework detection --
  case "$snippet $command" in
    *next*|*Next*|*NEXT*|*\.next/*|*next\.config*|*getServerSideProps*|*getStaticProps*|*app/api/*|*middleware\.ts*)
      framework="nextjs" ;;
    *react*|*React*|*useState*|*useEffect*|*jsx*|*JSX*|*component*|*Component*)
      framework="react" ;;
    *prisma*|*Prisma*|*PrismaClient*|*prisma\.schema*)
      framework="prisma" ;;
    *express*|*Express*|*app\.get*|*app\.post*|*router\.*|*middleware*)
      framework="express" ;;
    *vite*|*Vite*|*vite\.config*)
      framework="vite" ;;
    *webpack*|*Webpack*|*webpack\.config*)
      framework="webpack" ;;
    *jest*|*Jest*|*describe\(*|*it\(*|*expect\(*)
      framework="jest" ;;
    *vitest*|*Vitest*)
      framework="vitest" ;;
    *docker*|*Docker*|*Dockerfile*|*docker-compose*)
      framework="docker" ;;
    *supabase*|*Supabase*)
      framework="supabase" ;;
    *tailwind*|*Tailwind*|*@apply*)
      framework="tailwind" ;;
    *python*|*Python*|*pip*|*\.py:*|*Traceback*)
      framework="python" ;;
    *go\ *|*\.go:*|*go\ build*|*go\ run*)
      framework="go" ;;
    *rust*|*cargo*|*\.rs:*|*Cargo\.toml*)
      framework="rust" ;;
  esac

  # -- Detailed categorization --
  case "$snippet" in
    *"Cannot read prop"*|*"of undefined"*|*"of null"*|*"is not defined"*)
      category="runtime"; sub_category="null_reference" ;;
    *TypeError*)
      category="runtime"; sub_category="type_error" ;;
    *ReferenceError*)
      category="runtime"; sub_category="reference_error" ;;
    *"is not a function"*)
      category="runtime"; sub_category="not_function" ;;
    *"Maximum call stack"*|*"stack overflow"*)
      category="runtime"; sub_category="stack_overflow" ;;
    *RangeError*)
      category="runtime"; sub_category="range_error" ;;
    *TS2322*) category="type"; sub_category="type_mismatch" ;;
    *TS2345*) category="type"; sub_category="argument_type" ;;
    *TS2339*) category="type"; sub_category="property_missing" ;;
    *TS2304*) category="type"; sub_category="not_found" ;;
    *TS2307*) category="type"; sub_category="module_not_found" ;;
    *TS2531*|*TS2532*|*TS18047*|*TS18048*) category="type"; sub_category="possibly_null" ;;
    *TS7006*) category="type"; sub_category="implicit_any" ;;
    *TS[0-9][0-9][0-9][0-9]*|*"is not assignable"*|*"Type '"*) category="type"; sub_category="other" ;;
    *SyntaxError*|*"Unexpected token"*|*"Parse error"*|*"Unexpected end"*)
      category="syntax"; sub_category="parse_error" ;;
    *ENOENT*|*"No such file"*) category="module"; sub_category="file_not_found" ;;
    *MODULE_NOT_FOUND*|*"Cannot find module"*|*"Module not found"*) category="module"; sub_category="module_not_found" ;;
    *"Cannot resolve"*) category="module"; sub_category="resolve_error" ;;
    *FAIL*|*"test fail"*|*"Test failed"*|*"tests failed"*) category="test"; sub_category="test_failure" ;;
    *"assert"*|*"expect("*|*"toBe"*|*"toEqual"*) category="test"; sub_category="assertion" ;;
    *"Timeout"*test*|*"exceeded timeout"*) category="test"; sub_category="timeout" ;;
    *"Build fail"*|*"build error"*|*"compilation"*|*"Failed to compile"*)
      category="build"; sub_category="compilation" ;;
    *webpack*error*|*"Module build failed"*) category="build"; sub_category="bundler" ;;
    *"Permission denied"*|*EACCES*) category="permission"; sub_category="access" ;;
    *ECONNREFUSED*) category="network"; sub_category="connection_refused" ;;
    *ETIMEDOUT*|*timeout*|*"timed out"*) category="network"; sub_category="timeout" ;;
    *"fetch failed"*|*"network error"*) category="network"; sub_category="fetch" ;;
    *"relation"*"does not exist"*|*"table"*"not found"*) category="database"; sub_category="missing_table" ;;
    *"unique constraint"*|*"duplicate key"*) category="database"; sub_category="constraint" ;;
    *"deadlock"*) category="database"; sub_category="deadlock" ;;
    *"connection"*"refused"*|*"ECONNREFUSED"*5432*|*"ECONNREFUSED"*3306*) category="database"; sub_category="connection" ;;
    *ENOMEM*|*"out of memory"*|*"heap"*|*"JavaScript heap"*) category="memory"; sub_category="oom" ;;
    *eslint*|*ESLint*|*prettier*|*Prettier*) category="lint"; sub_category="style" ;;
    *"merge conflict"*|*"CONFLICT"*) category="git"; sub_category="conflict" ;;
    *"rejected"*|*"non-fast-forward"*) category="git"; sub_category="push_rejected" ;;
  esac

  echo "${category}|${sub_category}|${framework}"
}

# Calculate severity
calculate_severity() {
  local category="$1"
  case "$category" in
    build|database|memory) echo "critical" ;;
    runtime|type|permission) echo "high" ;;
    test|module|syntax|network) echo "medium" ;;
    lint|git|edit|write) echo "low" ;;
    *) echo "medium" ;;
  esac
}

# ============================================================
# EDIT/WRITE INTERMEDIATE OPERATIONS (for fix description)
# ============================================================

if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
  FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  TOOL_OUTPUT=$(echo "$TOOL_INPUT" | jq -r '.tool_output // empty' 2>/dev/null)

  if [ -f "$LAST_ERROR_FILE" ] && [ -n "$FILE_PATH" ] && [ "$EXIT_CODE" = "0" ]; then
    OLD_STR=$(echo "$TOOL_INPUT" | jq -r '.tool_input.old_string // empty' 2>/dev/null | head -c 100)
    NEW_STR=$(echo "$TOOL_INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null | head -c 100)

    if [ "$TOOL_NAME" = "Edit" ] && [ -n "$OLD_STR" ]; then
      OP_DESC="${TOOL_NAME}: ${FILE_PATH} (${OLD_STR:0:50} -> ${NEW_STR:0:50})"
    else
      OP_DESC="${TOOL_NAME}: ${FILE_PATH}"
    fi
    echo "$OP_DESC" >> "$PENDING_OPS_FILE"
  fi

  HAS_ERROR=false
  ERROR_SNIPPET=""

  if [ "$EXIT_CODE" != "0" ]; then
    HAS_ERROR=true
    ERROR_SNIPPET=$(echo "$TOOL_OUTPUT" | tail -3 | head -c 300)
  elif echo "$TOOL_OUTPUT" | grep -qi "error\|failed\|not found\|not unique\|BLOCKED" 2>/dev/null; then
    HAS_ERROR=true
    ERROR_SNIPPET=$(echo "$TOOL_OUTPUT" | grep -i "error\|failed\|not found\|not unique\|BLOCKED" | head -3 | head -c 300)
  fi

  if [ "$HAS_ERROR" = "true" ] && [ -n "$FILE_PATH" ]; then
    if ! is_duplicate "$FILE_PATH" "$ERROR_SNIPPET" "$SESSION_ID"; then
      ERROR_CAT="edit"
      [ "$TOOL_NAME" = "Write" ] && ERROR_CAT="write"
      SEVERITY=$(calculate_severity "$ERROR_CAT")

      RECORD=$(jq -c -n \
        --arg ts "$TIMESTAMP" \
        --arg session "$SESSION_ID" \
        --arg project "$PROJECT_DIR" \
        --arg project_hash "$PROJECT_HASH" \
        --arg tool "$TOOL_NAME" \
        --arg command "$FILE_PATH" \
        --argjson exit_code "${EXIT_CODE:-1}" \
        --arg error_snippet "$ERROR_SNIPPET" \
        --arg error_category "$ERROR_CAT" \
        --arg error_sub_category "" \
        --arg framework "" \
        --arg severity "$SEVERITY" \
        --argjson context_files "$(jq -n --arg f "$FILE_PATH" '[$f]')" \
        '{
          ts: $ts, session: $session, project: $project, project_hash: $project_hash,
          tool: $tool, command: $command, exit_code: $exit_code,
          error_snippet: $error_snippet, error_category: $error_category,
          error_sub_category: $error_sub_category, framework: $framework,
          severity: $severity, context_files: $context_files,
          fixed: false, fix_command: null, fix_description: null
        }')

      echo "$RECORD" >> "$ERRORS_FILE"
      echo "$RECORD" >> "$PROJECT_CONTEXT_FILE"

      rotate_file "$ERRORS_FILE" "$MAX_ERRORS"
      rotate_file "$PROJECT_CONTEXT_FILE" "$MAX_PROJECT_ERRORS"
    fi
  fi
fi

# ============================================================
# BASH TOOL HANDLING
# ============================================================

if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND=$(echo "$TOOL_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  TOOL_OUTPUT=$(echo "$TOOL_INPUT" | jq -r '.tool_output // empty' 2>/dev/null)

  if [ "$EXIT_CODE" != "0" ] && [ -n "$COMMAND" ]; then
    # ---- RECORD ERROR ----
    ERROR_SNIPPET=$(echo "$TOOL_OUTPUT" | tail -5 | head -c 500)

    if is_duplicate "$COMMAND" "$ERROR_SNIPPET" "$SESSION_ID"; then
      exit 0
    fi

    CLASSIFICATION=$(classify_error "$ERROR_SNIPPET" "$COMMAND")
    ERROR_CAT=$(echo "$CLASSIFICATION" | cut -d'|' -f1)
    SUB_CAT=$(echo "$CLASSIFICATION" | cut -d'|' -f2)
    FRAMEWORK=$(echo "$CLASSIFICATION" | cut -d'|' -f3)

    SEVERITY=$(calculate_severity "$ERROR_CAT")

    RAW_FILES=$(echo "$COMMAND $ERROR_SNIPPET" | grep -oE '[a-zA-Z0-9_./-]+\.(ts|tsx|js|jsx|py|go|rs|sh|json|yaml|yml|md|css|scss|vue|svelte)' 2>/dev/null | sort -u | head -5 || true)
    if [ -n "$RAW_FILES" ]; then
      CONTEXT_FILES=$(echo "$RAW_FILES" | jq -R . | jq -s . 2>/dev/null || echo "[]")
    else
      CONTEXT_FILES="[]"
    fi

    STACK_LOCATION=$(echo "$ERROR_SNIPPET" | grep -oE '(at [^ ]+ \()?[a-zA-Z0-9_./-]+\.[a-z]+:[0-9]+(:[0-9]+)?' 2>/dev/null | head -3 || true)
    if [ -n "$STACK_LOCATION" ]; then
      STACK_INFO=$(echo "$STACK_LOCATION" | jq -R . | jq -s . 2>/dev/null || echo "[]")
    else
      STACK_INFO="[]"
    fi

    RECORD=$(jq -c -n \
      --arg ts "$TIMESTAMP" \
      --arg session "$SESSION_ID" \
      --arg project "$PROJECT_DIR" \
      --arg project_hash "$PROJECT_HASH" \
      --arg tool "$TOOL_NAME" \
      --arg command "$COMMAND" \
      --argjson exit_code "$EXIT_CODE" \
      --arg error_snippet "$ERROR_SNIPPET" \
      --arg error_category "$ERROR_CAT" \
      --arg error_sub_category "$SUB_CAT" \
      --arg framework "$FRAMEWORK" \
      --arg severity "$SEVERITY" \
      --argjson context_files "$CONTEXT_FILES" \
      --argjson stack_locations "$STACK_INFO" \
      '{
        ts: $ts, session: $session, project: $project, project_hash: $project_hash,
        tool: $tool, command: $command, exit_code: $exit_code,
        error_snippet: $error_snippet, error_category: $error_category,
        error_sub_category: $error_sub_category, framework: $framework,
        severity: $severity, context_files: $context_files,
        stack_locations: $stack_locations,
        fixed: false, fix_command: null, fix_description: null
      }')

    echo "$RECORD" >> "$ERRORS_FILE"
    echo "$RECORD" >> "$PROJECT_CONTEXT_FILE"

    rm -f "$PENDING_OPS_FILE"

    jq -c -n \
      --arg command "$COMMAND" \
      --arg ts "$TIMESTAMP" \
      --arg errors_line "$(wc -l < "$ERRORS_FILE" | tr -d ' ')" \
      --arg project_line "$(wc -l < "$PROJECT_CONTEXT_FILE" | tr -d ' ')" \
      --arg error_category "$ERROR_CAT" \
      --arg error_sub_category "$SUB_CAT" \
      --arg framework "$FRAMEWORK" \
      --arg severity "$SEVERITY" \
      --arg error_snippet "$ERROR_SNIPPET" \
      '{command: $command, ts: $ts, errors_line: $errors_line, project_line: $project_line, error_category: $error_category, error_sub_category: $error_sub_category, framework: $framework, severity: $severity, error_snippet: $error_snippet}' \
      > "$LAST_ERROR_FILE"

    rotate_file "$ERRORS_FILE" "$MAX_ERRORS"
    rotate_file "$PROJECT_CONTEXT_FILE" "$MAX_PROJECT_ERRORS"

    maybe_auto_analyze

    # ============================================================
    # INSTANT FIX SUGGESTION: Show known solutions immediately
    # ============================================================
    if [ -f "$FIXES_FILE" ] && [ -n "$ERROR_CAT" ]; then
      KNOWN_FIXES=""
      if [ -n "$SUB_CAT" ]; then
        KNOWN_FIXES=$(jq -r --arg cat "$ERROR_CAT" --arg sub "$SUB_CAT" \
          'select(.error_category == $cat and .error_sub_category == $sub and .fix_description != null and .fix_description != "" and .fix_description != "(aradaki islemler kaydedilmedi)") | .fix_description' \
          "$FIXES_FILE" 2>/dev/null | sort -u | head -5)
      fi
      if [ -z "$KNOWN_FIXES" ]; then
        KNOWN_FIXES=$(jq -r --arg cat "$ERROR_CAT" \
          'select(.error_category == $cat and .fix_description != null and .fix_description != "" and .fix_description != "(aradaki islemler kaydedilmedi)") | .fix_description' \
          "$FIXES_FILE" 2>/dev/null | sort -u | head -3)
      fi

      if [ -n "$KNOWN_FIXES" ]; then
        FIX_COUNT=$(echo "$KNOWN_FIXES" | wc -l | tr -d ' ')
        echo ""
        echo "[Self-Healing] Known ${FIX_COUNT} solution(s) for this error type:"
        echo "$KNOWN_FIXES" | while IFS= read -r fix_line; do
          echo "  -> ${fix_line}" | head -c 200
          echo ""
        done
      fi
    fi

    # ============================================================
    # REGRESSION DETECTION: Previously fixed error reappearing?
    # ============================================================
    if [ -f "$ERRORS_FILE" ]; then
      REGRESSION_MATCH=$(jq -r --arg cmd "$COMMAND" --arg cat "$ERROR_CAT" --arg sub "$SUB_CAT" \
        'select(.command == $cmd and .error_category == $cat and .error_sub_category == $sub and .fixed == true) | .fix_description // "(no info)"' \
        "$ERRORS_FILE" 2>/dev/null | tail -1)

      if [ -n "$REGRESSION_MATCH" ] && [ "$REGRESSION_MATCH" != "null" ]; then
        echo ""
        echo "[Self-Healing] REGRESSION WARNING: This error was previously resolved!"
        echo "  Previous solution: ${REGRESSION_MATCH}" | head -c 200
        echo ""
        echo "  The same solution can be reapplied or a permanent fix may be needed."
      fi
    fi

  elif [ "$EXIT_CODE" = "0" ] && [ -f "$LAST_ERROR_FILE" ]; then
    # ---- FIX DETECTION ----
    LAST_CMD=$(jq -r '.command // empty' "$LAST_ERROR_FILE" 2>/dev/null)
    NORM_CMD=$(echo "$COMMAND" | tr -s '[:space:]' ' ' | xargs 2>/dev/null || echo "$COMMAND")
    NORM_LAST=$(echo "$LAST_CMD" | tr -s '[:space:]' ' ' | xargs 2>/dev/null || echo "$LAST_CMD")

    if [ "$NORM_CMD" = "$NORM_LAST" ] && [ -n "$NORM_CMD" ]; then
      ERRORS_LINE=$(jq -r '.errors_line // empty' "$LAST_ERROR_FILE" 2>/dev/null)
      PROJECT_LINE=$(jq -r '.project_line // empty' "$LAST_ERROR_FILE" 2>/dev/null)

      FIX_DESC=""
      if [ -f "$PENDING_OPS_FILE" ]; then
        OPS_COUNT=$(wc -l < "$PENDING_OPS_FILE" | tr -d ' ')
        if [ "$OPS_COUNT" -le 5 ]; then
          FIX_DESC=$(cat "$PENDING_OPS_FILE" | tr '\n' '; ' | sed 's/; $//')
        else
          FIRST_OPS=$(head -3 "$PENDING_OPS_FILE" | tr '\n' '; ' | sed 's/; $//')
          FIX_DESC="${FIRST_OPS}; ... and ${OPS_COUNT} more operations"
        fi
      fi
      [ -z "$FIX_DESC" ] && FIX_DESC="(intermediate operations not recorded)"

      FIX_FILES="[]"
      if [ -f "$PENDING_OPS_FILE" ]; then
        FIX_FILES=$(grep -oE '[a-zA-Z0-9_./-]+\.(ts|tsx|js|jsx|py|go|rs|sh|json|yaml|yml|md|css|scss|vue|svelte)' "$PENDING_OPS_FILE" 2>/dev/null | sort -u | head -10 | jq -R . | jq -s . 2>/dev/null || echo "[]")
      fi

      update_jsonl_line() {
        local file="$1"
        local target_line="$2"
        local desc="$3"
        local temp_file
        temp_file=$(mktemp)

        local current_line=0
        while IFS= read -r json_line; do
          current_line=$((current_line + 1))
          if [ "$current_line" -eq "$target_line" ]; then
            echo "$json_line" | jq -c --arg desc "$desc" \
              '.fixed = true | .fix_command = "auto" | .fix_description = $desc' 2>/dev/null || echo "$json_line"
          else
            echo "$json_line"
          fi
        done < "$file" > "$temp_file"
        mv "$temp_file" "$file"
      }

      if [ -n "$ERRORS_LINE" ] && [ -f "$ERRORS_FILE" ]; then
        update_jsonl_line "$ERRORS_FILE" "$ERRORS_LINE" "$FIX_DESC"
      fi

      if [ -n "$PROJECT_LINE" ] && [ -f "$PROJECT_CONTEXT_FILE" ]; then
        update_jsonl_line "$PROJECT_CONTEXT_FILE" "$PROJECT_LINE" "$FIX_DESC"
      fi

      FIX_RECORD=$(jq -c -n \
        --arg ts "$TIMESTAMP" \
        --arg session "$SESSION_ID" \
        --arg project "$PROJECT_DIR" \
        --arg project_hash "$PROJECT_HASH" \
        --arg command "$COMMAND" \
        --arg original_error_ts "$(jq -r '.ts // empty' "$LAST_ERROR_FILE" 2>/dev/null)" \
        --arg error_category "$(jq -r '.error_category // empty' "$LAST_ERROR_FILE" 2>/dev/null)" \
        --arg error_sub_category "$(jq -r '.error_sub_category // empty' "$LAST_ERROR_FILE" 2>/dev/null)" \
        --arg framework "$(jq -r '.framework // empty' "$LAST_ERROR_FILE" 2>/dev/null)" \
        --arg severity "$(jq -r '.severity // empty' "$LAST_ERROR_FILE" 2>/dev/null)" \
        --arg error_snippet "$(jq -r '.error_snippet // empty' "$LAST_ERROR_FILE" 2>/dev/null | head -c 200)" \
        --arg fix_description "$FIX_DESC" \
        --argjson fix_files "$FIX_FILES" \
        '{
          ts: $ts, session: $session, project: $project, project_hash: $project_hash,
          command: $command, original_error_ts: $original_error_ts,
          error_category: $error_category, error_sub_category: $error_sub_category,
          framework: $framework, severity: $severity, error_snippet: $error_snippet,
          fix_description: $fix_description, fix_files: $fix_files,
          type: "auto_fix_detected"
        }')
      echo "$FIX_RECORD" >> "$FIXES_FILE"

      rm -f "$LAST_ERROR_FILE" "$PENDING_OPS_FILE"
    fi
  fi
fi

exit 0
