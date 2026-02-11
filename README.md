# Self-Healing Claude

> A learning system for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that captures errors, remembers fixes, and gets smarter over time.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Compatible-blueviolet)](https://docs.anthropic.com/en/docs/claude-code)

---

## What is this?

Self-Healing Claude is a hook-based skill for Claude Code that **automatically captures errors**, **detects fixes**, and **injects learned context** into every new session. The more you use it, the fewer repeated mistakes Claude makes.

## Features

| Feature | Description |
|---------|-------------|
| **Error Capture** | Automatically captures errors from Bash, Edit, and Write tools with intelligent categorization (16 categories, 14 frameworks) |
| **Auto-Fix Detection** | When a previously failed command succeeds, the system records what changed between failure and success |
| **Instant Suggestions** | Known fixes are shown immediately when a familiar error occurs |
| **Regression Detection** | If a previously fixed error reappears, the system warns and shows the previous solution |
| **Pattern Analysis** | Periodic analysis extracts patterns, fix rates, severity distribution, and framework-specific insights |
| **Cross-Project Learning** | Lessons learned in one project are available in all your other projects |

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/pandnyr/self-healing-claude/main/install.sh | bash
```

Or clone and install manually:

```bash
git clone https://github.com/pandnyr/self-healing-claude.git
cd self-healing-claude
bash install.sh
```

## How It Works

```
Error occurs -> Hook captures it -> Saved to JSONL -> Next session reads it -> Same mistake avoided
     |              |                   |                        |
     v              v                   v                        v
[PostToolUse]   Categorize        Assign severity     [SessionStart Hook]
 exit code!=0   Sub-category      Detect framework    Inject recent errors
 parse error    Stack trace       Dedup check         Show multi-solutions
                                  Rotation            Cross-project learning
```

### Hook Chain

| Hook | Trigger | Action |
|------|---------|--------|
| `PostToolUse:Bash` | exit code != 0 | Categorize error and write to `errors.jsonl` |
| `PostToolUse:Edit\|Write` | Tool fails | Record file editing errors |
| `PostToolUse:Bash` | Previously failed command succeeds | Detect fix, write to `fixes.jsonl` |
| `SessionStart` | Every session start | Inject project-specific error context |

## Preloaded Knowledge

The system comes pre-loaded with **30 common error/fix pairs** across 8 categories, so it's useful from the very first session:

| Category | Count | Examples |
|----------|-------|---------|
| JS/TS Runtime | 6 | `Cannot read property of undefined`, `X is not a function`, `Maximum call stack` |
| TypeScript Types | 5 | `TS2322 Type mismatch`, `TS2339 Property missing`, `TS2531 Possibly null` |
| Module/Import | 3 | `Module not found`, `ENOENT`, `ERR_MODULE_NOT_FOUND` |
| React/Next.js | 6 | Hydration mismatch, Hook rules, Key prop, Re-render loop, `use client`, Dynamic server |
| Build/Dependency | 4 | `ERESOLVE`, Compile failure, Missing script, Peer dep |
| Test | 3 | Assertion failure, Timeout, Module resolve in tests |
| Database | 2 | Unique constraint, Connection refused |
| Git/Permission | 1 | SSH publickey |

## Configuration

After installation, hooks are automatically added to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash|Edit|Write",
        "command": "bash ~/.claude/skills/self-healing/scripts/capture-error.sh"
      }
    ],
    "SessionStart": [
      {
        "command": "bash ~/.claude/skills/self-healing/scripts/inject-context.sh"
      }
    ]
  }
}
```

See [`hooks.json`](hooks.json) for the hook template.

## CLI Commands

```bash
# View statistics
bash ~/.claude/skills/self-healing/scripts/cleanup.sh

# Remove resolved errors older than 30 days
bash ~/.claude/skills/self-healing/scripts/cleanup.sh --old

# Full reset (confirmation required)
bash ~/.claude/skills/self-healing/scripts/cleanup.sh --reset

# Run pattern analysis manually
bash ~/.claude/skills/self-healing/scripts/analyze-patterns.sh

# Re-run preload (after reset)
rm ~/.claude/self-healing/.preload_done
bash ~/.claude/skills/self-healing/scripts/preload.sh
```

## Architecture

### Data Flow

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Claude Code │────>│  PostToolUse │────>│  capture-     │
│  (Bash/Edit) │     │  Hook        │     │  error.sh     │
└──────────────┘     └──────────────┘     └──────┬───────┘
                                                  │
                     ┌────────────────────────────┼────────────────────┐
                     │                            │                    │
                     v                            v                    v
              ┌──────────┐              ┌──────────────┐    ┌──────────────┐
              │errors    │              │ fixes.jsonl  │    │project-      │
              │.jsonl    │              │              │    │contexts/     │
              │(max 500) │              │              │    │{hash}.jsonl  │
              └──────────┘              └──────────────┘    └──────────────┘
                     │                            │                    │
                     └────────────────────────────┼────────────────────┘
                                                  │
                                                  v
                                       ┌──────────────────┐
                                       │ inject-context.sh │
                                       │ (SessionStart)    │
                                       └──────────────────┘
                                                  │
                                                  v
                                       ┌──────────────────┐
                                       │ Claude sees past  │
                                       │ errors + fixes    │
                                       │ at session start   │
                                       └──────────────────┘
```

### Data Files

| File | Content | Max Size |
|------|---------|----------|
| `~/.claude/self-healing/errors.jsonl` | All error records | 500 lines |
| `~/.claude/self-healing/fixes.jsonl` | Successful fix records | - |
| `~/.claude/self-healing/patterns.json` | Extracted patterns + multi-solution | - |
| `~/.claude/self-healing/project-contexts/{hash}.jsonl` | Per-project memory | 200 lines |

### Error Classification

**16 categories:** runtime, type, build, dependency, test, lint, permission, syntax, network, config, docker, edit, git, database, memory, timeout

**4 severity levels:**
- `[!!!]` Critical - Segfault, OOM, data loss
- `[!!]` High - Build fail, test fail, runtime error
- `[!]` Medium - Lint, type error, deprecation
- `[-]` Low - Warning, permission, config

**14 frameworks detected:** Next.js, React, Prisma, Express, Jest, Vitest, Webpack, Vite, Supabase, Tailwind, Docker, Python, Go, Rust

## Intelligent Features

### Multi-Solution System
When the same error type has been fixed different ways, all known solutions are presented.

### Time-Based Decay
Resolved errors older than 30 days are automatically filtered from session context. Unresolved errors persist indefinitely.

### Deduplication
Same error from the same command in the same session is never recorded twice.

### Data Rotation
`errors.jsonl` is capped at 500 lines. During rotation, unresolved errors are prioritized over old resolved ones.

### Auto-Analysis
Every 20 errors, pattern analysis runs automatically in the background.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- `jq` (JSON processor)
  - macOS: `brew install jq`
  - Ubuntu/Debian: `sudo apt install jq`
  - Fedora: `sudo dnf install jq`

## Uninstall

```bash
# Download and run uninstaller (keeps learned data)
curl -fsSL https://raw.githubusercontent.com/pandnyr/self-healing-claude/main/uninstall.sh -o /tmp/uninstall-sh.sh && bash /tmp/uninstall-sh.sh

# Remove everything including learned data
curl -fsSL https://raw.githubusercontent.com/pandnyr/self-healing-claude/main/uninstall.sh -o /tmp/uninstall-sh.sh && bash /tmp/uninstall-sh.sh --purge
```

## FAQ

**Q: Does this slow down Claude Code?**
A: No. Error capture runs as a PostToolUse hook and completes in milliseconds. Pattern analysis runs in the background.

**Q: Does it send data anywhere?**
A: No. All data stays local in `~/.claude/self-healing/`. Nothing is sent to any server.

**Q: Can I use it with multiple projects?**
A: Yes. Each project gets its own context file, and cross-project learning shares insights between them.

**Q: How do I reset everything?**
A: Run `bash ~/.claude/skills/self-healing/scripts/cleanup.sh --reset`

**Q: Does it work on Linux?**
A: Yes. All scripts handle both macOS (`date -j`) and GNU/Linux (`date -d`) date formats.

## License

[MIT](LICENSE)
