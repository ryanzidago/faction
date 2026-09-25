-- Checks that every declared function and module starts on a def/defmodule
-- line. Run against faction.duckdb with the absolute repository root:
--   printf "SET VARIABLE root = '/abs/app';\n.read /abs/validation/check_lines.sql\n" | duckdb faction.duckdb
CREATE OR REPLACE TEMP TABLE src AS
SELECT regexp_replace(filename, '^' || getvariable('root') || '/', '') AS path, string_split(content, chr(10)) AS lines
FROM read_text(getvariable('root') || '/**/*.ex')
WHERE filename NOT LIKE getvariable('root') || '/deps/%' AND filename NOT LIKE getvariable('root') || '/_build/%';

SELECT count(*) AS declared_functions,
       count(*) FILTER (WHERE f.end_line < f.start_line) AS bad_range,
       count(*) FILTER (WHERE f.end_line IS NULL) AS no_end_line,
       count(*) FILTER (WHERE NOT regexp_matches(s.lines[f.start_line], '\bdef(p|macro|macrop|guard|guardp|delegate)?\b')) AS no_def_on_start_line
FROM functions f JOIN src s USING (path)
WHERE NOT f.is_generated;

SELECT count(*) AS declared_modules,
       count(*) FILTER (WHERE NOT regexp_matches(s.lines[m.start_line], '\bdef(module|impl|protocol)\b')) AS no_defmodule_on_start_line
FROM modules m JOIN src s USING (path)
WHERE NOT m.is_generated;

SELECT f.module, f.function, f.arity, f.path, f.start_line, s.lines[f.start_line] AS line
FROM functions f JOIN src s USING (path)
WHERE NOT f.is_generated AND NOT regexp_matches(s.lines[f.start_line], '\bdef(p|macro|macrop|guard|guardp|delegate)?\b')
LIMIT 20;
