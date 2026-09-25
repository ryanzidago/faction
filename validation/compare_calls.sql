-- Compares function_calls into application modules with a compiler trace.
-- Run against faction.duckdb, loading the trace first:
--   printf "CREATE OR REPLACE TABLE trace AS SELECT * FROM read_json('/abs/trace.jsonl');\n.read /abs/validation/compare_calls.sql\n" \
--     | duckdb faction.duckdb
-- Lines are ignored and "name (overridable N)" is folded into "name": the
-- tracer sees functions before defoverridable renames them. Expected
-- differences are listed in README.md.
CREATE OR REPLACE TEMP TABLE plain AS SELECT DISTINCT module, function, arity FROM functions;

CREATE OR REPLACE TEMP TABLE traced AS
SELECT tr.caller_module,
       CASE WHEN p.module IS NULL AND m.module IS NOT NULL THEN m.function ELSE tr.caller_function END AS caller_function,
       CASE WHEN p.module IS NULL AND m.module IS NOT NULL THEN m.arity ELSE tr.caller_arity END AS caller_arity,
       tr.callee_module, tr.callee_function, tr.callee_arity
FROM trace tr
LEFT JOIN plain p ON p.module = tr.caller_module AND p.function = tr.caller_function AND p.arity = tr.caller_arity
LEFT JOIN plain m ON m.module = tr.caller_module AND m.function = 'MACRO-' || tr.caller_function AND m.arity = tr.caller_arity + 1;

CREATE OR REPLACE TEMP TABLE tracer_calls AS
SELECT caller_module, regexp_replace(caller_function, ' \(overridable \d+\)$', '') AS caller_function, caller_arity,
       callee_module, regexp_replace(callee_function, ' \(overridable \d+\)$', '') AS callee_function, callee_arity, count(*) AS n
FROM traced
WHERE callee_module IN (SELECT module FROM modules)
  AND callee_function NOT IN ('behaviour_info', '__info__', '__schema__', '__struct__', '__changeset__')
GROUP BY ALL;

CREATE OR REPLACE TEMP TABLE faction_calls AS
SELECT caller_module, regexp_replace(caller_function, ' \(overridable \d+\)$', '') AS caller_function, caller_arity,
       callee_module, regexp_replace(callee_function, ' \(overridable \d+\)$', '') AS callee_function, callee_arity, count(*) AS n
FROM function_calls
WHERE callee_module IN (SELECT module FROM modules)
  AND callee_function NOT IN ('behaviour_info', '__info__', '__schema__', '__struct__', '__changeset__')
GROUP BY ALL;

SELECT (SELECT count(*) FROM (SELECT * FROM tracer_calls INTERSECT SELECT * FROM faction_calls)) AS same,
       (SELECT count(*) FROM (SELECT * FROM tracer_calls EXCEPT SELECT * FROM faction_calls)) AS only_tracer,
       (SELECT count(*) FROM (SELECT * FROM faction_calls EXCEPT SELECT * FROM tracer_calls)) AS only_faction;

-- Calls Faction has fewer of than the tracer: each needs an explanation.
SELECT t.caller_module, t.caller_function, t.caller_arity, t.callee_module, t.callee_function, t.callee_arity,
       t.n AS tracer_n, f.n AS faction_n
FROM tracer_calls t
LEFT JOIN faction_calls f USING (caller_module, caller_function, caller_arity, callee_module, callee_function, callee_arity)
WHERE coalesce(f.n, 0) < t.n
ORDER BY t.n - coalesce(f.n, 0) DESC
LIMIT 50;
