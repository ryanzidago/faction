# Beads Workflow Context

Follow `AGENTS.md` for this repository's workflow.

## Task tracking

- Use `mise exec -- bd` for all durable task tracking.
- Give every new issue a concise, descriptive, human-readable ID using
  `mise exec -- bd create --id faction-<kebab-case-summary> ...`; never rely on
  an opaque generated ID. Immediately rename an accidentally generated ID with
  `mise exec -- bd rename <old-id> faction-<kebab-case-summary>`.
- Run `bd ready` and `bd show <id>` before starting existing work; create an issue
  before writing code for new work, then claim it with `bd update <id> --claim`.
- Store persistent project memory with `bd remember`; recover it with `bd memories`.
  Do not create separate memory files or Markdown task lists.
- After context recovery, run `bd memories` to load current shared project memory.
- Close an issue with `bd close <id>` only once its work is merged to main (or,
  for non-code work, verified live); leave unmerged work `in_progress` with a note.

## Git and worktrees

Beads storage is local-only. This does not prohibit local Git operations or
dedicated Worktrunk worktrees, including when no Git remote is configured.
Follow the worktree instructions in `AGENTS.md`.

Commits, merges, pushes, and Beads remote sync require explicit user authorization.
Do not commit, merge, push, or sync merely to finish a Beads session.

## Session handoff

Run checks appropriate to the change, close issues whose work is merged, inspect the changes,
and report results and remaining limitations. Leave unfinished work in Beads with
enough context for the next session.
