# faction

Static analysis of compiled BEAM files into flat JSONL relations that an AI agent queries with DuckDB. Read `PRINCIPLES.md` before changing anything.
Tour the API, data model and example queries with `mise run tour:livebook` (interactive, `guides/tour.livemd`) or `mise run tour` (self-checking, terminal, `guides/tour.exs`).

- Run tools through mise (`mise run <task>`, `mise exec -- <cmd>`) so pinned versions are used.
- See `mise.toml` for additional tools relevant to this project.
- Prefer project-local tool config (Claude, Codex, beads, etc.) over global config.
- Work in a worktree: `mise exec -- wt switch --create <branch> --yes`.
- Removing or merging a worktree cleans it up; don't clean up by hand.
- Track work with `mise exec -- bd` (see `.config/beads/PRIME.md`).
- Close a beads issue only once its work is merged to main; until then leave it `in_progress` with a note on what's pending.
- Prefer merge over rebase; merging is simpler.
- Run `mise run qa` (`mix precommit`) when a change is done.
- Faction never loads or compiles the target project; it reads BEAM files only. DuckDB is the query interface; Faction itself has no DuckDB dependency.
- Tests live next to the code in `lib/` (`foo_test.exs`); no `setup` or `describe`, no `Process.sleep`.
- Every `def` and `defp` has a `@spec`.
- Pre-release: no backward compatibility. Change shapes directly instead of adding shims.
- Stay in scope: design and build the smallest thing that meets the request; mention extras instead of doing them.
- Ask before committing, merging, or pushing.
