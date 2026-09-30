# Faction

Faction gives an AI agent a structured, queryable map of an Elixir codebase,
so it can answer code questions with fewer tokens and less guessing.

It reads compiled BEAM files, extracts compiler facts into flat JSONL relations,
and writes SQL to load them into DuckDB. Agents can query:

- Who calls a function, and what does it call?
- What could be affected by changing it, and which tests call it?
- Which modules implement a behaviour?
- What Ecto schemas, fields, associations, and Phoenix routes exist?
- Where is a function defined?

Compiler facts resolve aliases, imports, captures, and macro-generated calls
that text search can miss. Unresolved dynamic calls are recorded separately,
so agents can see where answers may be incomplete.

**Faction extracts facts; the agent interprets them.** It never loads or compiles
the target project. Derived answers, such as transitive callers, belong in SQL
queries. Faction has no DuckDB dependency and produces no runtime traces,
scores, or recommendations. It targets single Mix applications; umbrellas are
not supported.

Try the self-checking tour with `mise run tour`, or the interactive version with
`mise run tour:livebook`. Read [PRINCIPLES.md](PRINCIPLES.md) for the design,
data model, and example queries.

## Getting started

Build the CLI in this repository with `mise exec -- mix escript.build`, then put
the resulting `faction` executable on your PATH. From your already compiled Mix
application's root (replace `my_app` with its application name):

```sh
faction --deps _build/dev/lib _build/dev/lib/my_app/ebin
cd out
duckdb faction.duckdb < schema.sql
duckdb faction.duckdb
```

## Data model

`schema.sql` loads each JSONL relation into a typed DuckDB table: one row per
fact, with scalar columns that can be filtered and joined directly.

| Table | What it stores |
| --- | --- |
| `modules` | Application modules, generated status, and source file/line ranges. |
| `functions` | Functions by module, name, and arity; visibility, generated status, default-argument target arity, and source locations. |
| `function_calls` | Each resolved call or capture: caller, callee, kind, and source location. |
| `dynamic_function_calls` | Unresolved call sites: caller, location, and callee name/arity when known. |
| `module_references` | Literal Elixir modules used as values inside functions, with caller and location. |
| `behaviours` | Behaviours declared by each application module, including protocol implementations. |
| `callbacks` | Behaviour contracts: callback name, arity, and whether it is optional, including contracts from dependencies. |
| `ecto_schemas` | Ecto schema modules and database table names; embedded schemas have no table name. |
| `ecto_fields` | Persisted schema fields, their types, and primary-key status. Virtual fields are excluded. |
| `ecto_assocs` | Associations and embeds: name, kind, and related schema when known. |
| `routes` | Phoenix routes: router, HTTP verb, path pattern, route kind, destination module, and action. |

Functions share the identity `(module, function, arity)`. Calls use the same
three columns with `caller_` and `callee_` prefixes, making joins straightforward.
`modules` and `functions` inventory the supplied application BEAMs, including
tests when supplied; calls may also point to dependencies, Elixir, or Erlang.

DuckDB also exposes derived views:

| View | What it answers |
| --- | --- |
| `external_functions` | Which called functions are absent from the application inventory? |
| `callback_impls` | Which application functions fulfil declared behaviour callbacks? |
| `test_modules` | Which modules contain ExUnit tests or are defined in the same source files? |
| `faction_columns` | What tables/views and columns exist, with their types and explanatory comments? |

Source paths are relative to the repository root. Missing facts, such as an
unavailable source location, use `NULL`. Change impact and other derived answers
are computed with queries over these relations.

## Example questions

Run these queries in DuckDB. The `MyApp` names come from the
[tour fixture](fixtures/my_app); replace them with your application's names.

**What facts can I query?** The database describes its own schema:

```sql
FROM faction_columns;
```

**Where is `list_orders/1` defined?**

```sql
SELECT path, start_line, end_line
FROM functions
WHERE module = 'MyApp.Orders' AND function = 'list_orders' AND arity = 1;
```

**Who calls it?** Includes direct calls and function captures:

```sql
SELECT caller_module, caller_function, caller_arity, kind, path, line
FROM function_calls
WHERE callee_module = 'MyApp.Orders'
  AND callee_function = 'list_orders' AND callee_arity = 1
ORDER BY ALL;
```

**What does the controller action call?**

```sql
SELECT callee_module, callee_function, callee_arity, line
FROM function_calls
WHERE caller_module = 'MyAppWeb.OrderController'
  AND caller_function = 'index' AND caller_arity = 2
ORDER BY ALL;
```

**What could be affected if I change `query/1`?** Follow callers transitively:

```sql
WITH RECURSIVE affected(module, function, arity) AS (
  SELECT 'MyApp.Orders', 'query', 1
  UNION
  SELECT c.caller_module, c.caller_function, c.caller_arity
  FROM function_calls c JOIN affected a
    ON c.callee_module = a.module
    AND c.callee_function = a.function AND c.callee_arity = a.arity
)
SELECT * FROM affected ORDER BY ALL;
```

**Which tests call `list_orders/1`?** Test BEAMs must also be indexed; see
[the test compilation guide](guides/compile_tests.exs).

```sql
SELECT c.caller_module, c.caller_function, c.path, c.line
FROM function_calls c JOIN test_modules t ON t.module = c.caller_module
WHERE c.callee_module = 'MyApp.Orders'
  AND c.callee_function = 'list_orders' AND c.callee_arity = 1
ORDER BY ALL;
```

**Which routes reach this controller action?**

```sql
SELECT verb, route, router
FROM routes
WHERE module = 'MyAppWeb.OrderController' AND action = 'index'
ORDER BY ALL;
```

**Which modules implement `Oban.Worker`, and which callbacks do they provide?**

```sql
SELECT module, function, arity
FROM callback_impls
WHERE behaviour = 'Oban.Worker'
ORDER BY ALL;
```

**What fields and associations does the order schema have?**

```sql
SELECT field, type, is_primary_key
FROM ecto_fields WHERE module = 'MyApp.Orders.Order';

SELECT name, kind, related_module
FROM ecto_assocs WHERE module = 'MyApp.Orders.Order';
```

These are static relationships. Dynamic dispatch and framework entry points
can make a call graph incomplete; use the facts to guide investigation.
