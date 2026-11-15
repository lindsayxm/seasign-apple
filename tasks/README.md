# tasks

A file-per-task kanban. Each task is one markdown file (`0042-fix-login.md`). Agents never edit these files by hand; they use the `task` CLI, which validates every state change and writes atomically. A hook blocks freehand edits by Claude, through the edit tools and through the shell.

## States

```
backlog → todo → in-progress → review → done
                 ↑    ↓  ↑        │
                 │  blocked       │
                 └────────────────┘  (review → in-progress for rework)

any state except done → cancelled    (task cancel, with a reason)
```

| from | to |
|---|---|
| backlog | todo, cancelled |
| todo | in-progress (via `claim`), backlog, blocked, cancelled |
| in-progress | review, todo (release; clears owner), blocked, cancelled |
| review | done, in-progress, cancelled |
| blocked | todo, in-progress (if it still has an owner), cancelled |
| done | — |
| cancelled | — |

`done` and `cancelled` are both closed: `list --open` hides them and they cannot be reopened. A cancelled task does not satisfy a dependency; point the dependent task elsewhere with `task edit <id> --depends ...`.

## Commands

Run from the project folder as `./tasks/task <command>`.

| command | what it does |
|---|---|
| `new "title" [--goal t] [--accept t]... [--files a,b] [--depends 1,2] [--todo]` | create a task (in `backlog`, or `todo` with `--todo`) |
| `list [--status s] [--open] [--json]` | list tasks; `--open` hides done and cancelled. `[2/3]` after a title is criteria met |
| `show <id>` | print the task file |
| `claim <id> [--owner name]` | take a `todo` task: sets owner, moves to `in-progress`. Fails if already owned or a dependency is unfinished |
| `update <id> --status <s>` | move between states (validated) |
| `note <id> "text"` | append to the task's log |
| `tried <id> "text"` | record an approach and how it went |
| `set <id> goal\|criteria\|files "text"` | replace a section |
| `edit <id> [--title t] [--depends 1,2\|none]` | change the title or the dependencies of an open task. The file name keeps its original slug |
| `check <id> <n>` | tick acceptance criterion number `n` (counted from 1). `uncheck <id> <n>` undoes it |
| `block <id> "reason"` | move to `blocked` with a reason |
| `done <id>` | `review` → `done`; warns if any criterion is still unchecked |
| `cancel <id> "reason"` | close a task that will not be finished |
| `serve [--port 4242]` | live board at http://127.0.0.1:4242 |

Text arguments accept `-` to read from stdin. Identity comes from `--owner`/`--by`, then `$TASK_OWNER`, then `$USER`.

## Task file

```markdown
---
id: 42
title: Fix login redirect
status: todo
owner:
depends_on: [7]
created: 2026-01-01T10:00:00Z
updated: 2026-01-01T10:00:00Z
---

## Goal
## Acceptance criteria
## Relevant files
## What's been tried
## Log
```

A task must make sense to an agent with no other context: say what to achieve, how to tell it is done, which files matter, and what has already been attempted. The log is append-only.

## Conventions

- Put the task ID in every commit message: `[#42] fix redirect loop`. Then `git log --grep '\[#42\]'` shows everything done for the task. A hook rejects commits without `[#N]` or `[no-task]`.
- The lock that makes `claim` atomic is per checkout. If subagents work in separate git worktrees, the lead claims the task in the main checkout before handing it out.
- The rule against editing task files applies to agents. A person can still fix one in an editor; keep the frontmatter keys and the `## ` headings intact, and write criteria as `- [ ] text` lines so `check` can find them.
