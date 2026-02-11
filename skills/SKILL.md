---
name: self-healing
description: "A learning system that gets better over time by learning from errors."
version: 2.0.0
allowed-tools:
  - Read
  - Edit
  - Write
  - Bash
  - Grep
  - Glob
---

# Self-Healing

**Auto-use when:** error, fix, debug, solution, not working, same issue, previously fixed

**Works with:** quality skill - enriches error records

---

## How It Works

```
Error occurs -> Hook captures it -> Saved to JSONL -> Next session reads it -> Same mistake avoided
     |              |                 |                        |
     v              v                 v                        v
[PostToolUse]   Categorize      Assign severity     [SessionStart Hook]
 exit code!=0   Sub-category     Detect framework    Inject recent errors
 parse error    Stack trace      Dedup check         Show multi-solutions
                                 Rotation            Cross-project learning
```

### Hook Chain

| Hook | Trigger | Action |
|------|---------|--------|
| `PostToolUse:Bash` | exit code != 0 | Categorize error and write to `errors.jsonl` |
| `PostToolUse:Edit\|Write` | Tool fails | Record file editing errors |
| `PostToolUse:Bash` | Previously failed command succeeds | Detect fix, write to `fixes.jsonl` |
| `SessionStart` | Every session start | Inject project-specific error context |

---

## Error Capture

The hook automatically records:
- **Timestamp**, session ID, project directory
- **Failed command** and error snippet (first meaningful line)
- **Error category**: runtime, type, build, dependency, test, lint, permission, syntax, network, config, docker, edit, git, database, memory, timeout
- **Sub-category**: null_reference, type_mismatch, module_not_found, missing_script, assertion_failed, etc.
- **Severity**: critical, high, medium, low
- **Framework detection**: nextjs, react, prisma, jest, vitest, webpack, vite, eslint, docker, python, go, rust, swift, kotlin (14 frameworks)
- **Stack trace locations**: file:line pairs
- **Affected files**: file paths extracted from error messages

Storage: `~/.claude/self-healing/errors.jsonl`
Per-project: `~/.claude/self-healing/project-contexts/{hash}.jsonl`

### Record Format (JSONL)

```json
{
  "ts": "2026-02-11T10:30:00Z",
  "session": "abc123",
  "project": "/path/to/project",
  "project_hash": "a1b2c3d4e5f6",
  "tool": "Bash",
  "command": "npm test",
  "exit_code": 1,
  "error_snippet": "TypeError: Cannot read property 'map' of undefined",
  "error_category": "runtime",
  "error_sub_category": "null_reference",
  "framework": "jest",
  "severity": "high",
  "stack_locations": ["src/List.tsx:42", "src/App.tsx:15"],
  "context_files": ["src/components/List.tsx"],
  "fixed": false
}
```

---

## Smart Categorization

### Severity Levels

| Severity | Condition | Icon |
|----------|-----------|------|
| critical | Segfault, OOM, data loss, corruption | `[!!!]` |
| high | Build fail, test fail, runtime error | `[!!]` |
| medium | Lint, type error, deprecation | `[!]` |
| low | Warning, permission, config | `[-]` |

### Framework Detection

14 different frameworks are automatically detected from commands and error messages:
`nextjs`, `react`, `prisma`, `jest`, `vitest`, `webpack`, `vite`, `eslint`, `docker`, `python`, `go`, `rust`, `swift`, `kotlin`

---

## Fix Detection Protocol

When a previously failed command succeeds:
1. Intermediate Edit/Write operations are tracked in `.pending-ops`
2. Fix description is enriched from intermediate operations (which files were edited)
3. The record in `errors.jsonl` is updated to `fixed: true`
4. Fix info is also written to `fixes.jsonl` (includes `error_category`, `error_sub_category`, `error_snippet` for multi-solution)

---

## Multi-Solution System

The same error type may have different solutions. The system manages this:

### Recording
- Each fix is saved to `fixes.jsonl` with `error_category`, `error_sub_category`, `error_snippet` and `fix_description`
- Different `fix_description` values for the same category+sub-category are treated as multi-solutions

### Display (inject-context.sh)
- **For resolved errors**: Main solution shown + "Alternative solutions:" list for same type
- **For unresolved errors**: All known solutions shown as "Known N solutions:"

### Analysis (analyze-patterns.sh)
- Each pattern gets an `alternative_fixes` array
- Up to 5 different solutions stored per pattern in `patterns.json`

---

## Session Start Context Injection

Every session start, `inject-context.sh` runs and provides:

1. **Project-specific errors**: Past errors listed by severity
2. **Stack trace locations**: File:line info shown (`@ src/List.tsx:42`)
3. **Severity icon**: `[!!!]` critical, `[!!]` high, `[!]` medium, `[-]` low
4. **Framework info**: Which framework the error occurred in
5. **Multi-solution**: Alternative solutions for resolved, known solutions for unresolved
6. **Error distribution**: Category + severity statistics
7. **Fix rate**: Fix success percentage for the project
8. **Framework distribution**: Error count per framework
9. **Recurring unresolved errors**: Unresolved critical/high errors prioritized
10. **Cross-project learning**: Lessons learned from other projects with example fixes
11. **Pattern insights**: Global and framework-specific suggestions from `patterns.json`

### Time-Based Decay
- 30-day window: Resolved errors older than 30 days are filtered from context
- Unresolved errors are always shown (no timeout)

---

## Data Safety

### Deduplication
- Same error from same command in same session is never recorded twice
- Last 5 records checked (session + command matching)

### Data Rotation
- `errors.jsonl`: Maximum 500 lines (priority: unresolved errors preserved)
- `project-contexts/{hash}.jsonl`: Maximum 200 lines
- During rotation, old resolved errors are deleted first; unresolved errors preserved as much as possible

### Auto Pattern Analysis
- Every 20 errors, `analyze-patterns.sh` triggers automatically in background
- Manual execution also available

---

## Instant Fix Suggestion (Real-time)

When an error occurs, known solutions are shown **immediately**. Claude Code sees this suggestion and can apply it directly.

**How it works:**
- After `capture-error.sh` records an error, it searches `fixes.jsonl` for known solutions with matching `error_category + error_sub_category`
- If found, outputs `[Self-Healing] Known N solutions for this error type:` to stdout
- Claude Code sees this output as PostToolUse hook result and evaluates it

**Example output:**
```
[Self-Healing] Known 2 solutions for this error type:
  -> Edit: src/List.tsx (items.map -> items?.map);
  -> Edit: src/Card.tsx (data.title -> data?.title ?? "Untitled");
```

---

## Regression Detection

If a previously resolved error reappears, an automatic warning is given.

**How it works:**
- When a new error is recorded, `errors.jsonl` is searched for matching command + category/sub_category with `fixed: true`
- If found, shows previous solution with "REGRESSION WARNING"
- Claude Code can reapply the same solution or make a permanent fix

**Example output:**
```
[Self-Healing] REGRESSION WARNING: This error was previously resolved!
  Previous solution: Edit: src/List.tsx (items.map -> items?.map);
  The same solution can be reapplied or a permanent fix may be needed.
```

---

## Weekly Trend

At session start, a weekly comparison is shown:
- This week vs last week error count
- Increase/decrease percentage
- This week's fix rate

---

## Preloaded Knowledge

The system comes pre-loaded with 30 common error/fix pairs on first install. This means instant fix suggestions and regression detection work from the very first session.

**Auto-trigger:** `inject-context.sh` checks for marker file at each session start. If missing, `preload.sh` runs automatically.

**Coverage (8 categories, 30 entries):**
- JavaScript/TypeScript Runtime: 6
- TypeScript Type: 5
- Module/Import: 3
- React/Next.js: 6
- Build/Dependency: 4
- Test: 3
- Database: 2
- Git/Permission: 1

**Idempotent:** `.preload_done` marker prevents duplicate loading.

---

## Cleanup

```bash
bash ~/.claude/skills/self-healing/scripts/cleanup.sh           # Statistics
bash ~/.claude/skills/self-healing/scripts/cleanup.sh --old      # Remove resolved errors older than 30 days
bash ~/.claude/skills/self-healing/scripts/cleanup.sh --reset    # Delete all data (confirmation required)
```

---

## Cross-Project Learning

Error/fix experiences are shared across different projects:
1. **Common error types**: Grouped by category+sub-category
2. **Solution examples**: Successfully applied fixes from other projects are shown
3. **Project health score**: `analyze-patterns.sh` calculates fix rate per project

---

## Pattern Analysis

With `analyze-patterns.sh`:
- Most frequent errors are grouped and normalized
- Fix rate, affected projects, severity, framework calculated per pattern
- **Multi-solution**: Different solutions collected as `alternative_fixes` per pattern
- Global insights extracted (most frequent category, fix rate commentary, severity distribution)
- Framework-specific insights generated
- Cross-project analysis performed (common errors, project health scores)
- `patterns.json` generated

---

## Data Files

| File | Content | Max Size |
|------|---------|----------|
| `~/.claude/self-healing/errors.jsonl` | All error records | 500 lines |
| `~/.claude/self-healing/fixes.jsonl` | Successful fix records | - |
| `~/.claude/self-healing/patterns.json` | Extracted patterns + multi-solution | - |
| `~/.claude/self-healing/project-contexts/{hash}.jsonl` | Per-project memory | 200 lines |
| `~/.claude/self-healing/.last-error` | Last error info (for fix detection) | 1 record |
| `~/.claude/self-healing/.pending-ops` | Pending operations for fix detection | Temporary |
