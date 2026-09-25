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

## Synthetic scale target

`synthetic_app.exs` generates a seeded Phoenix app (one Mix project) with a
given number of application BEAMs, lines of code and routes. Its defaults are
the scale target in `PRINCIPLES.md`: `--beams 10000 --lines 3000000 --routes 3000`.

It builds the app the way a team would:

1. **Skeleton.** `mix phx.new` and `mix phx.gen.auth --live`.
   - It needs the `phx_new` 1.8.14 archive and fails with any other version.
   - It adds Oban, Absinthe (with `absinthe_plug`) and Localize, with their
     config, Oban in the supervision tree and `/api/graphql` in the router.
   - The random secrets are replaced with fixed ones.
   - The dependencies are pinned by `synthetic_app.lock`. The first
     `deps.get` needs network access.
2. **Scaffold.** Phoenix's own generators, run in one process by
   `synthetic_scaffold.exs`.
   - Resources with routes use `phx.gen.live`, `phx.gen.html` or
     `phx.gen.json` (half of them LiveViews), enough for `--routes`.
   - Every other resource uses `phx.gen.context`.
   - A context holds 1 or more resources (3.5 on average), and contexts are
     grouped in namespaces of 200 (`Synth.Part01.Ctx17`).
   - Every route goes into the one `SynthWeb.Router`. `test/` and the
     migrations are removed.
3. **Growth.** Five modules in every context:
   - a query module;
   - a `Synth.Worker` behaviour implementation;
   - a protocol implementation;
   - a `defoverridable` module;
   - an Ecto schema with `belongs_to` into another context.

   Some contexts get more:
   - half an Oban job, which the context enqueues;
   - a quarter GraphQL: Absinthe types for every resource, imported by the
     one `SynthWeb.Schema`, and a resolver module;
   - about one in seven a GenServer, started by its namespace's
     `Supervisor` (one per namespace, in the application's children).

   It also adds functions to the generated contexts, LiveView `Index` modules
   and HTML modules: Ecto queries and changesets, `with` pipelines, logging,
   Localize formatting, Gettext, helpers, function components, and calls into
   other contexts. Contexts call each other in a skewed pattern, so a few
   become hubs with large fan-in.

   The extra lines are spread with a long tail: most contexts stay small and a
   few reach about 10,000 lines.

The totals match the flags exactly:
- `--beams` counts every module declaration in `lib/`, one BEAM each, plus
  `SynthWeb.Schema.Compiled`, which Absinthe generates.
- `--lines` counts every line of `lib/**/*.{ex,heex}`, unless the scaffold
  alone needs more lines.
- The route count comes out within a few routes above `--routes`.

The same flags always write the same files.

```
mise run synthetic -- --beams 10000 --lines 3000000 --routes 3000 --seed 1 --out $APP
cd $APP && /usr/bin/time -l mix compile
./faction --root $APP --out $OUT --deps $APP/_build/dev/lib $APP/_build/dev/lib/synth/ebin
```

Most of the compile time is the router: at 3,000 routes it takes several
minutes on one core (compile plus Elixir's type check), as it would in a real
app with that many routes.

Next to the app it writes an oracle:
- `manifest.json`: expected counts, including `routes` and `live_views`, the
  total `lines`, `largest_module` and `largest_module_lines`.
- `expected_calls.jsonl`: every call it wrote into a context module from
  another context, a query module, a GenServer, an Oban job or a resolver,
  with its line.

`check_synthetic.sql` compares Faction's output with it. Expected: all zeros.
`mix phx.routes | grep -c "^ "` must equal `routes`. The other checks above
apply as well.

### Density

A run is only a valid scale measurement if its code is as dense as a real
app's. `check_synthetic.sql` reports the density per 1,000 lines. Read BEAM
bytes with `du -sk $APP/_build/dev/lib/synth/ebin`.

The targets are the range between Plausible and changelog.com. They are
measured the same way for every app: over every source line that compiles into
the app's BEAMs, templates included, and Plausible's `extra/lib` too.

| Per 1,000 lines | Plausible | changelog.com | Target | Synthetic 1k | Synthetic 10k |
| --- | --- | --- | --- | --- | --- |
| `function_calls` rows | 687 | 1,052 | 690–1,050 | 855 | 789 |
| Functions | 115 | 195 | 115–195 | 164 | 170 |
| BEAM bytes | 246 KB | 198 KB | 200–250 KB | 222 KB | 211 KB |
