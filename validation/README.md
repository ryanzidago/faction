# Validation harness

Checks for climbing the target ladder in `PRINCIPLES.md` (rungs 2–4). Faction
itself never compiles anything; these scripts compile or query a target to
check Faction's output against independent sources.

For a target app at `$APP` (absolute path), after `mix deps.get && mix compile`:

1. **Run Faction** with the escript (`MIX_ENV=prod mix escript.build`) and
   record wall time and peak memory:

   ```
   /usr/bin/time -l ./faction --root $APP --out $OUT --deps $APP/_build/dev/lib $APP/_build/dev/lib/<app>/ebin
   cd $OUT && duckdb faction.duckdb < schema.sql
   ```

   Nothing should be skipped, and every behaviour should resolve.

2. **Definition lines** (`check_lines.sql`): every declared function and
   module must start on a `def…`/`defmodule…` line. Expected: all zeros.

3. **External callees** (`check_external.exs`): every callee outside the app
   must be exported by its module. Expected: all `exported`; a literal
   `apply/3` to a function that does not exist is a real call site.

4. **Calls against the compiler** (`tracer.exs`, `compare_calls.sql`):
   recompile with the tracer, then compare calls into application modules.

   ```
   cd $APP && TRACE_OUT=$APP/trace.jsonl elixir -r $FACTION/validation/tracer.exs -S mix compile --force
   ```

   Faction reports the compiled BEAM; the tracer sees expansion. Known,
   expected differences:

   - Faction only: calls in generated code the tracer does not see
     (Phoenix `Router.Helpers`, default-argument dispatch such as
     `newest_first/0` → `newest_first/2`).
   - Tracer only: calls in `defoverridable` originals discarded by an
     override without `super`; default-argument expressions, which the tracer
     attributes to the full arity and Faction to the shorter arity that runs
     them; macro arguments expanded more than once (Ecto `from` bindings).

   Any other difference is a bug until explained.

Results for rungs 2 and 3 are in the beads issues `faction-rung2-library` and
`faction-rung3-apps`.
