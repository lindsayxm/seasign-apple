---
name: session-wrap-up
description: End-of-session routine - settle the task board, record decisions, append a dated entry to PROJECT-STATUS.md, and commit. Use when the user says they are done for the day, asks to wrap up, or before ending any development session.
---

# Session wrap-up

Do these in order.

1. **Board.** Run `./tasks/task list --open`. For each task that is `in-progress`:
   - finished and verified: move it to `review` (or `done` if it has been reviewed);
   - not finished: add a `note` saying exactly where it stands and what comes next, and leave it claimed only if the same owner will continue; otherwise release it with `update <id> --status todo`.
2. **Working tree.** Run `git status`. Commit finished work with its task ID. Do not commit half-done work to make the tree clean; say in the status entry that it is uncommitted.
3. **Decisions.** For each lasting decision made this session (a stack choice, a data-model choice, a rule), add a file `memory/decisions/YYYY-MM-DD-short-name.md` with the decision, the reason, and what was rejected. Put looser observations in `memory/notes/`. Update `memory/architecture.md` if the structure changed.
4. **Status entry.** Append one entry to the end of `PROJECT-STATUS.md` with the Edit tool (the file is append-only; a hook rejects anything else). Use today's date and this format:

   ```markdown
   ## YYYY-MM-DD — one-line summary

   - Done: what was finished, with task IDs
   - In flight: what is partly done
   - Next: what the next session should pick up first
   - Notes: blockers, open questions, links to plans/ or memory/
   ```

   Write it for a session that has none of this conversation: name task IDs and file paths, not "the thing we discussed".
5. **Commit** the status entry and memory files: `git commit -m "[no-task] session wrap-up YYYY-MM-DD"`.
6. **Tell the user** in a few lines: what got done, what is in flight, and what comes first next time.
