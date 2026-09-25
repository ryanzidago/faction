# Faction principles

## Goal

Give an AI agent a **structured, queryable map of an Elixir codebase**, so it
navigates by asking questions instead of grepping.

Grep is flaky for code: it matches comments, strings, aliases, and misses
imports, captures and macro-generated calls. The compiler already knows the real
answers. Faction extracts them from the compiled BEAMs into DuckDB-queryable
tables.

Questions it must answer exactly:

- Which functions call `MyApp.Orders.list_orders/1`?
- What does `MyAppWeb.OrderController.index/2` call?
- If I change this function, what could break (transitive callers)?
- Which public functions are never called?
- Which modules implement this behaviour, and which functions are its callbacks?
- What Ecto schemas exist, with which fields and associations?
- Where is this function defined (file and lines)?

Out of scope for now: runtime traces, test execution data, and any judgement
("this is bad"). Faction reports facts about the code; the agent reasons.

Every feature must pass one test: *does it let an agent answer a question with
fewer tokens and less guessing?* If not, it is cut.

## Principles

1. **The compiler is the source of truth.** Facts come from compiled BEAM debug
   info. Source files only add locations (path, lines). Faction never compiles,
   fetches, or loads the target project; it only reads BEAM files.
2. **Facts, not interpretation.** Anything derivable by a query (transitive
   callers, dead code, fan-in) is a query, never a stored column.
3. **Flat relations.** One file per relation, one row per fact, scalar columns
   only. No nested objects, so every column works in `WHERE` and `JOIN`.
4. **One identity scheme.** A function is always `(module, function, arity)`.
   The same three columns appear in every relation that mentions a function, so
   any two relations join without translation.
5. **Inventory is application-only.** `modules` and `functions` list only code
   compiled in this project. Referenced dependencies and stdlib appear only as
   callees in `function_calls`; the `external_functions` view derives them. NULL
   is used only where a fact is genuinely absent (for example, no source
   definition), never as a stand-in for "false".
6. **Deterministic.** Same BEAMs, same output files. Each BEAM's rows are
   written in a fixed order, and BEAMs are merged in sorted path order even
   when processed in parallel. Faction does not globally sort; queries use
   `ORDER BY`. No timestamps.
7. **Scales by streaming.** Large codebases must not need the whole index in
   memory. Extract one BEAM at a time and append rows to the output as you go.
   Memory use is bounded by the largest single module, not the project size.
8. **Small surface.** One command, few flags, no caches in v1. Add speed
   machinery only against a measured problem.
9. **Self-describing.** The agent learns the schema from the database
   (`DESCRIBE`, column comments), not from a README.

## Scale target

Design for a monorepo application with **~100,000 BEAM files**. At that size
`function_calls` alone can reach tens of millions of rows, so:

- **Per-BEAM extraction, no global state.** Each BEAM is read, turned into rows,
  and released. No step needs another BEAM's result, so BEAMs can be processed
  in parallel with bounded concurrency.
- **No cross-project dedup or merging in Faction.** External modules and
  functions are not written as rows; they are a SQL view derived from `function_calls`
  (and `behaviours`), computed by DuckDB at query time.
- **One bounded second pass for behaviours.** After per-BEAM extraction,
  collect the distinct set of behaviours declared by application modules
  (hundreds of names, not millions of rows), read each behaviour's BEAM once
  (application or dependency `ebin`), and emit `callbacks` rows from its
  `behaviour_info/1`. No whole-project state is needed.
- **Append-only writes.** Rows are streamed to disk as produced, never
  accumulated in a list or map before writing.
- **Measured, not assumed.** The definition of done for each slice includes a run
  on the 100k-BEAM project with peak memory and wall time recorded here.

Target numbers (to fill in from the first real run):

| Metric | Old Faction | Target |
| --- | --- | --- |
| Wall time on the 100k-BEAM app | ? | ? |
| Peak memory | ? | ? |

## Output

One JSONL file per relation, streamed by Faction, plus a `schema.sql`.
Running `schema.sql` with the `duckdb` CLI loads the JSONL once into a
`faction.duckdb` file: typed tables, a comment on every column, and the
`external_functions` view. The agent queries that file, for example
`duckdb faction.duckdb "SELECT ..."`.

Querying raw JSONL directly re-parses it on every query, which is too slow at
tens of millions of rows, so the agent never does that. Faction itself has no
DuckDB dependency: it writes JSONL and SQL text.

```
out/
  modules.jsonl
  functions.jsonl
  function_calls.jsonl
  dynamic_function_calls.jsonl
  behaviours.jsonl
  callbacks.jsonl
  callback_impls.jsonl
  ecto_schemas.jsonl
  ecto_fields.jsonl
  ecto_assocs.jsonl
  schema.sql   (loads the JSONL into faction.duckdb; defines external_functions)
```

## Compiler details

Rules taken from the compiled output (and the legacy implementation) that the
data model must state explicitly:

- **Identity is the compiled name.** Macros keep their BEAM names, such as
  `MACRO-build`, and their compiled arity (source arity + 1).
- **Default arguments** compile to several arities. Each arity is its own
  function row, all pointing at the same definition range.
- **Compiler-generated functions** (`module_info`, `__info__`, `__struct__`,
  and functions from macros like `use`) are listed with `is_generated = true`.
  `is_generated` means: no direct source declaration exists, or the compiler
  marked it generated.
- **Generated modules** whose recorded source lies outside the repository keep
  their rows but have NULL path and lines; dependency source is never reported
  as an application definition.
- **Behaviour callbacks** come from literal `behaviour_info/1` forms in the
  behaviour's BEAM, including behaviours from dependencies.
- **Ecto schemas** come from the `__schema__/1`, `__schema__/2`, and
  `__changeset__/0` forms in the BEAM's abstract code. No module is loaded.

## Data model by example

The rows below are **illustrative** until rung 1 generates real output from
compiled BEAMs; the real rows will then replace them. They are incomplete on
purpose: the `from(...)` macro in `query/1` and the `use` line expand into more
calls and generated functions than are shown.

Given this tiny app:

```elixir
# lib/my_app/orders.ex
defmodule MyApp.Orders do                                   # line 1
  def list_orders(user_id) do                               # line 2
    user_id |> query() |> MyApp.Repo.all()                  # line 3
  end                                                       # line 4
                                                            # line 5
  defp query(user_id), do: from(o in Order, where: ...)     # line 6
end

# lib/my_app_web/order_controller.ex
defmodule MyAppWeb.OrderController do                       # line 1
  use MyAppWeb, :controller                                 # line 2
  def index(conn, _params) do                               # line 3
    orders = MyApp.Orders.list_orders(conn.assigns.user_id) # line 4
    render(conn, :index, orders: orders)                    # line 5
  end                                                       # line 6
end
```

### `modules.jsonl`

```json
{"module":"MyApp.Orders","is_generated":false,"path":"lib/my_app/orders.ex","start_line":1,"end_line":7}
{"module":"MyAppWeb.OrderController","is_generated":false,"path":"lib/my_app_web/order_controller.ex","start_line":1,"end_line":7}
```

### `functions.jsonl`

```json
{"module":"MyApp.Orders","function":"list_orders","arity":1,"visibility":"public","is_generated":false,"path":"lib/my_app/orders.ex","start_line":2,"end_line":4}
{"module":"MyApp.Orders","function":"query","arity":1,"visibility":"private","is_generated":false,"path":"lib/my_app/orders.ex","start_line":6,"end_line":6}
{"module":"MyAppWeb.OrderController","function":"index","arity":2,"visibility":"public","is_generated":false,"path":"lib/my_app_web/order_controller.ex","start_line":3,"end_line":6}
```

### `function_calls.jsonl`

One row per call *occurrence*: two calls to the same function on different
lines are two rows. `kind` is `call` for `f(x)` and `capture` for `&f/1`.

```json
{"caller_module":"MyApp.Orders","caller_function":"list_orders","caller_arity":1,"callee_module":"MyApp.Orders","callee_function":"query","callee_arity":1,"kind":"call","path":"lib/my_app/orders.ex","line":3}
{"caller_module":"MyApp.Orders","caller_function":"list_orders","caller_arity":1,"callee_module":"MyApp.Repo","callee_function":"all","callee_arity":1,"kind":"call","path":"lib/my_app/orders.ex","line":3}
{"caller_module":"MyAppWeb.OrderController","caller_function":"index","caller_arity":2,"callee_module":"MyApp.Orders","callee_function":"list_orders","callee_arity":1,"kind":"call","path":"lib/my_app_web/order_controller.ex","line":4}
{"caller_module":"MyAppWeb.OrderController","caller_function":"index","caller_arity":2,"callee_module":"Phoenix.Controller","callee_function":"render","callee_arity":3,"kind":"call","path":"lib/my_app_web/order_controller.ex","line":5}
```

Calls the compiler cannot resolve (`apply(mod, fun, args)`, dynamic module
variables) are rows in `dynamic_function_calls` with the caller and location only, so
the agent knows the answer to "who calls X?" may be incomplete near that site.

### Behaviours and callbacks

```json
// behaviours.jsonl: module declares a behaviour
{"module":"MyApp.Workers.Mailer","behaviour":"Oban.Worker"}
// callbacks.jsonl: the behaviour's contract
{"behaviour":"Oban.Worker","function":"perform","arity":1}
// callback_impls.jsonl: function fulfils a callback
{"module":"MyApp.Workers.Mailer","function":"perform","arity":1,"behaviour":"Oban.Worker"}
```

### Ecto

```json
// ecto_schemas.jsonl
{"module":"MyApp.Orders.Order","source_table":"orders"}
// ecto_fields.jsonl
{"module":"MyApp.Orders.Order","field":"id","type":"id","is_primary_key":true}
{"module":"MyApp.Orders.Order","field":"total","type":"decimal","is_primary_key":false}
// ecto_assocs.jsonl
{"module":"MyApp.Orders.Order","name":"user","kind":"belongs_to","related_module":"MyApp.Accounts.User"}
```

## Example queries

All queries run against `faction.duckdb`.

Who calls `list_orders/1`?

```sql
SELECT caller_module, caller_function, caller_arity, path, line
FROM function_calls
WHERE callee_module = 'MyApp.Orders' AND callee_function = 'list_orders' AND callee_arity = 1;
```

What does `index/2` call?

```sql
SELECT callee_module, callee_function, callee_arity, line
FROM function_calls
WHERE caller_module = 'MyAppWeb.OrderController' AND caller_function = 'index' AND caller_arity = 2;
```

Blast radius: everything that transitively calls `query/1`.

```sql
WITH RECURSIVE up(module, function, arity) AS (
  SELECT 'MyApp.Orders', 'query', 1
  UNION
  SELECT c.caller_module, c.caller_function, c.caller_arity
  FROM function_calls c JOIN up
    ON c.callee_module = up.module AND c.callee_function = up.function AND c.callee_arity = up.arity
)
SELECT * FROM up;
```

Public application functions that nothing calls:

```sql
SELECT f.module, f.function, f.arity, f.path, f.start_line
FROM functions f
WHERE f.visibility = 'public'
  AND NOT EXISTS (
    SELECT 1 FROM function_calls c
    WHERE c.callee_module = f.module AND c.callee_function = f.function AND c.callee_arity = f.arity);
```

(Callback implementations, `dynamic_function_calls`, and framework entry points make this
a candidate list, not a verdict. The agent decides.)

## Non-goals for v1

- Runtime traces and test-execution data.
- Test-file call collection.
- Caches, sharding, or concurrency knobs.
- Umbrella projects.
- A DuckDB writer inside Faction.
- Backward compatibility with the old format.
- Findings, scoring, or recommendations.

Each may return only with a concrete failing use case behind it.

## Build order

Two axes: **relations** (what we extract) and **targets** (what we extract it
from). Build relations as thin vertical slices, each usable end to end before
the next:

1. `modules`, `functions` → JSONL + `schema.sql`.
2. `function_calls`, `dynamic_function_calls`.
3. `behaviours`, `callbacks`, `callback_impls`.
4. Ecto relations.

Validate every slice by climbing the target ladder. Do not move up a rung until
the current one is boringly correct.

| Rung | Target | What it tests |
| --- | --- | --- |
| 1 | Tiny fixture app (the example above) | Correctness: every relation matches hand-written expected output; every example query returns the expected rows. This rung defines "correct" for all others. |
| 2 | A small open source library | Real compiler output: macros, `use`, generated functions, captures, protocols, behaviours. |
| 3 | Plausible, changelog.com | Realistic app shape: Ecto, Phoenix, LiveView, many dependencies. First real time and memory measurements, compared against the old Faction. |
| 4 | The ~100k-BEAM monorepo application | Scale: does the streaming design hold. Run only once rung 3 is boring. |

Scale sanity check at rung 3: also run on a synthetic project (many trivial
modules, or replicated BEAMs) at increasing file counts and confirm peak memory
stays flat. This checks the scaling behaviour without waiting on the monorepo.

## Verification

- Correctness is defined by the rung-1 fixture, not by the implementation.
- Every example query in this file is run against real output and must return
  the expected rows.
- From rung 3 up, record wall time and peak memory in the Scale target table.
- Rung 3 output is compared with the old Faction as a sanity check only;
  differences are investigated, not assumed to be bugs in either tool.

## Open questions

- Exact definition of the `external_functions` view: callees in `function_calls`
  that are absent from `functions`. Callback contracts for external behaviours
  come from `callbacks`, not this view.
- Is `kind` on `function_calls` enough, or do captures deserve their own relation?
- Do we record repository metadata (repo, commit) at all? If the agent always
  runs inside the repo, it may not be needed.
