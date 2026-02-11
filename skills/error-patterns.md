# Known Error Patterns

In addition to patterns automatically learned by the self-healing system,
these are common known error patterns and their solutions.

## JavaScript / TypeScript

| Pattern | Solution |
|---------|----------|
| `Cannot read property '...' of undefined` | Add optional chaining `?.` |
| `Cannot read property '...' of null` | Add null check or `??` default value |
| `X is not a function` | Check import, correct export? |
| `X is not defined` | Missing import or scope error |
| `Maximum call stack exceeded` | Infinite recursion, add base case |
| `Unexpected token` | Syntax error, check parentheses/quotes |
| `Module not found` | `npm install` or fix import path |
| `TS2322: Type X not assignable to Y` | Update interface/type or cast |
| `TS2339: Property does not exist` | Add to interface or fix typo |
| `TS2345: Argument type mismatch` | Fix parameter type |
| `TS2531: Object is possibly null` | `!` assertion or `?.` optional chain |

## Build & Bundler

| Pattern | Solution |
|---------|----------|
| `ENOENT: no such file or directory` | Check file path, `mkdir -p` |
| `Cannot resolve module` | Check import alias/path mapping |
| `Unexpected token in JSON` | Check JSON syntax, trailing comma |
| `ENOMEM: not enough memory` | `NODE_OPTIONS=--max_old_space_size=4096` |
| `Port already in use` | `lsof -i :PORT` to find, `kill` |

## Test

| Pattern | Solution |
|---------|----------|
| `expect(received).toBe(expected)` | Check assertion value |
| `Timeout - async callback` | `async/await` or increase timeout |
| `Cannot find module` (test) | Jest/Vitest config path mapping |
| `Mock not called` | Check mock setup order |

## Git

| Pattern | Solution |
|---------|----------|
| `merge conflict` | Resolve conflict markers (`<<<<`) |
| `detached HEAD` | `git checkout main` |
| `rejected (non-fast-forward)` | `git pull --rebase` then push |

## Docker

| Pattern | Solution |
|---------|----------|
| `COPY failed: file not found` | Check Dockerfile context and .dockerignore |
| `network not found` | `docker network create` |
| `port already allocated` | Another container using same port |

## Database

| Pattern | Solution |
|---------|----------|
| `connection refused` | Check if DB service is running |
| `relation does not exist` | Run migration |
| `unique constraint violation` | Duplicate data, use upsert |
| `deadlock detected` | Fix transaction order |

---

> This file is a static reference. For dynamically learned patterns, check `~/.claude/self-healing/patterns.json`.
