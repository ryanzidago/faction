-- Compares Faction's output on a synthetic app with the generator's oracle.
-- Run against faction.duckdb, loading the oracle first:
--   printf "CREATE OR REPLACE TABLE expected_calls AS SELECT * FROM read_json('/abs/expected_calls.jsonl');\nCREATE OR REPLACE TABLE manifest AS SELECT * FROM read_json('/abs/manifest.json');\n.read /abs/validation/check_synthetic.sql\n" \
--     | duckdb faction.duckdb
-- Expected: every diff is 0, and every density figure (per 1,000 lines of
-- lib/) inside its target from validation/README.md.
-- The oracle covers every call into a context module from another context,
-- a query module, a GenServer, an Oban job or a GraphQL resolver module.
CREATE OR REPLACE TEMP MACRO is_context(m) AS regexp_full_match(m, 'Synth\.Part\d+\.Ctx\d+');
CREATE OR REPLACE TEMP MACRO is_caller(m) AS regexp_full_match(m, 'Synth\.Part\d+\.Ctx\d+(\.Query|\.Server|\.Jobs\.\w+)?|SynthWeb\.Resolvers\.Part\d+\.Ctx\d+');

CREATE OR REPLACE TEMP TABLE edges AS
SELECT caller_module, caller_function, caller_arity, callee_module, callee_function, callee_arity, kind, path, line
FROM function_calls
WHERE is_caller(caller_module) AND is_context(callee_module) AND callee_module <> caller_module;

CREATE OR REPLACE TEMP TABLE expected AS
SELECT caller_module, caller_function, caller_arity, callee_module, callee_function, callee_arity, kind, path, line
FROM expected_calls;

SELECT 'missing call edges' AS "check", count(*) AS diff FROM (FROM expected EXCEPT ALL FROM edges)
UNION ALL
SELECT 'extra call edges', count(*) FROM (FROM edges EXCEPT ALL FROM expected)
UNION ALL
SELECT 'modules', (SELECT count(*) FROM modules) - (SELECT modules FROM manifest)
UNION ALL
SELECT 'ecto schemas', (SELECT count(*) FROM ecto_schemas) - (SELECT schemas FROM manifest)
UNION ALL
SELECT 'Synth.Worker impls', (SELECT count(*) FROM behaviours WHERE behaviour = 'Synth.Worker') - (SELECT workers FROM manifest)
UNION ALL
SELECT 'Oban workers', (SELECT count(*) FROM behaviours WHERE behaviour = 'Oban.Worker') - (SELECT jobs FROM manifest)
UNION ALL
SELECT 'GenServers', (SELECT count(*) FROM behaviours WHERE behaviour = 'GenServer') - (SELECT servers FROM manifest)
UNION ALL
SELECT 'Supervisors', (SELECT count(*) FROM behaviours WHERE behaviour = 'Supervisor') - (SELECT supervisors FROM manifest)
UNION ALL
SELECT 'LiveViews', (SELECT count(*) FROM behaviours WHERE behaviour = 'Phoenix.LiveView') - (SELECT live_views FROM manifest)
UNION ALL
SELECT 'dynamic calls in contexts',
       (SELECT count(*) FROM dynamic_function_calls WHERE is_context(caller_module)) - (SELECT dynamic_calls FROM manifest);

SELECT 'function_calls' AS "per 1,000 lines", round((SELECT count(*) FROM function_calls) * 1000 / (SELECT lines FROM manifest)) AS value, '690-1,050' AS target
UNION ALL
SELECT 'functions', round((SELECT count(*) FROM functions) * 1000 / (SELECT lines FROM manifest)), '115-195';
