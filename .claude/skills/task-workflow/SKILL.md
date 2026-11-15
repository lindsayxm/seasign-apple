---
name: task-workflow
description: How the lead session runs work through the local task board - turning BUILD.md into tasks, claiming, delegating to the implementer and reviewer subagents, and closing tasks. Use when planning work, starting a task, handing a task to a subagent, or deciding whether a task is done.
---

# Task workflow

The board in `tasks/` is the only tracker for this project. There are no GitHub issues, projects or Actions. Every change goes through `./tasks/task` (see `tasks/README.md` for all commands and the state diagram).

## 1. Turn work into tasks

Write each task so an agent with no other context can do it:

```sh
./tasks/task new "Today screen: date and next three events" \
  --goal "Show today's date and the next three EventKit events on the Today screen." \
  --accept "Events come from EventKit, soonest first, at most three" \
  --accept "Calendar permission denied shows an explanation, not an empty list" \
  --accept "xcodebuild test passes" \
  --files ios/Seasign/Today/TodayView.swift,ios/Seasign/Calendar/EventStore.swift \
  --depends 6 --todo
```

- One task is one reviewable change. Split a task that touches both `api/` and `ios/` unless the change is trivial.
- Criteria are things someone can check by running something. Include the test command.
- Use `--depends` when order matters. A task that changes the OpenAPI spec comes before the iOS task that uses the new client.
- New tasks start in `backlog`. Move one to `todo` (`--todo`, or `update <id> --status todo`) when it is ready to be picked up.

## 2. Claim, then work or delegate

```sh
./tasks/task claim <id> --owner lead          # or --owner implementer-1
```

- Claim before any work starts. The lead claims on behalf of a subagent, then starts the `implementer` agent with only the task ID.
- One task per subagent. Run tasks in parallel only when their "Relevant files" do not overlap.
- If you do the task yourself, follow the same steps the implementer does: `note` what you did, `tried` what failed, commit as `[#<id>] ...`, then `update <id> --status review`.

## 3. Review

- Start the `reviewer` agent with the task ID once the task is in `review`. It ticks the criteria it has verified and logs a verdict; it does not change code or status.
- For iOS UI tasks, the review includes a Simulator screenshot (XcodeBuildMCP) compared against the criteria.
- Pass: `./tasks/task done <id>`. Changes needed: `./tasks/task update <id> --status in-progress`, then send it back with the reviewer's notes in the log.

## 4. Other moves

| situation | command |
|---|---|
| Stuck on something outside the task | `./tasks/task block <id> "reason"` and tell the user |
| Giving a task back unfinished | `./tasks/task update <id> --status todo` (clears the owner) |
| Task no longer needed | `./tasks/task cancel <id> "reason"` |
| Found extra work while implementing | do not do it; `./tasks/task new ...` |

Nothing is `done` until its criteria have been checked by someone other than the agent that wrote the code.
