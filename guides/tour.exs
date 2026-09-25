# A guided, self-checking tour of Faction.
#
#     mise run tour                          # the fixture app, every answer checked
#     mise run tour -- --app /abs/path/app   # also a compiled Mix app of yours
#
# It compiles the fixture app in fixtures/my_app (the tour does, Faction never
# compiles anything), runs Faction on its BEAMs, loads the output into DuckDB
# and walks through the API, the data model, the questions an agent asks, and
# the compiler rules behind the answers. Every answer is compared with the
# expected rows; any mismatch stops the tour with a non-zero exit.
# TOUR_QUIET=1 keeps the checks and drops the narration.

Code.require_file("../fixtures/fixture.exs", __DIR__)

defmodule Faction.Tour do
  @moduledoc false

  alias Faction.Fixture
  alias Faction.Relation

  @spec main(argv :: list(String.t())) :: :ok
  def main(argv) do
    {opts, _args, _invalid} = OptionParser.parse(argv, strict: [app: :string, ebin: :string])
    Process.put(:checks, 0)

    out = setup()
    api(out)
    data_model(out)
    questions(out)
    compiler_rules(out)
    if opts[:app], do: real_app(opts[:app], opts[:ebin])

    section("Done")
    say("#{Process.get(:checks)} checks passed.")
    say("Explore the fixture yourself: cd #{out} && duckdb faction.duckdb")
  end

  # -- 1. Setup ---------------------------------------------------------------

  @spec setup() :: Path.t()
  defp setup do
    section("1. Setup")

    System.find_executable("duckdb") ||
      raise "duckdb is not on PATH; run the tour with `mise run tour`"

    say(
      "Compiling the fixture app (fixtures/my_app) and its stand-in dependencies (fixtures/deps)."
    )

    Fixture.compile!()

    out = Path.join(System.tmp_dir!(), "faction-tour-#{System.unique_integer([:positive])}")
    say("Output directory: #{out}")
    out
  end

  # -- 2. API -----------------------------------------------------------------

  @spec api(out :: Path.t()) :: :ok
  defp api(out) do
    section("2. API")

    say("""
    Faction has one entry point. From Elixir:

        Faction.run([ebin_dir, ...], root: repo_root, out: out_dir, deps: [dep_ebins])

    From a shell (escript: MIX_ENV=prod mix escript.build, or `mix faction`):

        faction --root #{Fixture.root()} --out #{out} \\
          --deps #{Fixture.deps_ebin()} #{Fixture.app_ebin()}

    Every BEAM in the ebin directories is application code. --deps is read only
    to find the callbacks of behaviours from dependencies.
    """)

    summary =
      Faction.run([Fixture.app_ebin()],
        root: Fixture.root(),
        out: out,
        deps: [Fixture.deps_ebin()]
      )

    say("Summary returned by Faction.run/2:\n\n" <> inspect(summary, pretty: true) <> "\n")

    check!(
      "every fixture BEAM was extracted, none skipped",
      summary.beams == 20 and summary.skipped == []
    )

    check!("every declared behaviour resolved to a BEAM", summary.missing_behaviours == [])

    say(
      "Files written:\n\n" <> Enum.map_join(Enum.sort(File.ls!(out)), "\n", &"    #{&1}") <> "\n"
    )

    say("schema.sql loads them into DuckDB: cd #{out} && duckdb faction.duckdb < schema.sql")

    {_output, 0} =
      System.cmd("duckdb", ["faction.duckdb", "-f", "schema.sql"],
        cd: out,
        stderr_to_stdout: true
      )

    :ok
  end

  # -- 3. Data model ----------------------------------------------------------

  @samples %{
    modules:
      "SELECT * FROM modules WHERE module IN ('MyApp.Orders', 'MyApp.Csv') ORDER BY module",
    functions:
      "SELECT * FROM functions WHERE module = 'MyApp.Orders' OR (module = 'MyApp.Shapes' AND function = 'area') ORDER BY module, function, arity",
    function_calls:
      "SELECT * FROM function_calls WHERE caller_module = 'MyApp.Orders' ORDER BY callee_module",
    dynamic_function_calls:
      "SELECT * FROM dynamic_function_calls WHERE caller_module = 'MyApp.Dispatch'",
    behaviours: "SELECT * FROM behaviours ORDER BY module",
    callbacks:
      "SELECT * FROM callbacks WHERE behaviour IN ('Oban.Worker', 'MyApp.Notifier') ORDER BY ALL",
    ecto_schemas: "SELECT * FROM ecto_schemas ORDER BY module",
    ecto_fields: "SELECT * FROM ecto_fields WHERE module = 'MyApp.Orders.Line'",
    ecto_assocs: "SELECT * FROM ecto_assocs WHERE module = 'MyApp.Orders.Order'",
    external_functions:
      "SELECT * FROM external_functions WHERE module IN ('Phoenix.Controller', 'String') ORDER BY ALL",
    callback_impls: "SELECT * FROM callback_impls WHERE behaviour <> 'GenServer' ORDER BY ALL"
  }

  @spec data_model(out :: Path.t()) :: :ok
  defp data_model(out) do
    section("3. Data model")

    say("""
    One JSONL file per relation, one row per fact, scalar columns only. A
    function is always (module, function, arity) and every relation that
    mentions one uses the same three columns, so any two relations join
    directly. Derivable facts are views, not files. The schema describes
    itself: every table, view and column has a comment in DuckDB, and
    `FROM faction_columns` lists them all.
    """)

    uncommented =
      sql!(
        out,
        "SELECT count(*) AS n FROM duckdb_columns() WHERE comment IS NULL AND NOT internal"
      )

    check!("every column of every table and view has a comment", uncommented == [%{"n" => 0}])

    tables =
      Enum.map(Relation.all(), &{&1.name, "table"}) ++
        Enum.map(Relation.views(), &{&1.name, "view"})

    for {name, kind} <- tables do
      subsection("#{name} (#{kind})")

      [%{"comment" => comment}] =
        sql!(out, "SELECT comment FROM duckdb_#{kind}s() WHERE #{kind}_name = '#{name}'")

      say(comment <> "\n")

      show(
        out,
        "SELECT column_name, data_type, comment FROM faction_columns WHERE table_name = '#{name}'"
      )

      say("Sample rows:")
      show(out, Map.fetch!(@samples, name))
    end

    subsection("Locations point at source")
    say("functions.path/start_line/end_line for MyApp.Orders.list_orders/1, and those lines:")

    [row] =
      sql!(out, """
      SELECT path, start_line, end_line FROM functions
      WHERE module = 'MyApp.Orders' AND function = 'list_orders' AND arity = 1
      """)

    source_lines(row["path"], row["start_line"], row["end_line"])

    check!(
      "list_orders/1 spans lib/my_app/orders.ex lines 2-4",
      row == %{"path" => "lib/my_app/orders.ex", "start_line" => 2, "end_line" => 4}
    )

    :ok
  end

  # -- 4. Questions an agent asks ---------------------------------------------

  @spec questions(out :: Path.t()) :: :ok
  defp questions(out) do
    section("4. Questions an agent asks")

    ask!(
      out,
      "Where is MyApp.Orders.list_orders/1 defined?",
      """
      SELECT path, start_line, end_line FROM functions
      WHERE module = 'MyApp.Orders' AND function = 'list_orders' AND arity = 1
      """,
      [%{"path" => "lib/my_app/orders.ex", "start_line" => 2, "end_line" => 4}]
    )

    ask!(
      out,
      "Who calls list_orders/1? (a direct call, a capture &list_orders/1, and apply/3 with literals)",
      """
      SELECT caller_module, caller_function, caller_arity, kind, path, line FROM function_calls
      WHERE callee_module = 'MyApp.Orders' AND callee_function = 'list_orders' AND callee_arity = 1
      ORDER BY caller_module, caller_function
      """,
      [
        %{
          "caller_module" => "MyApp.Dispatch",
          "caller_function" => "captures",
          "caller_arity" => 0,
          "kind" => "capture",
          "path" => "lib/my_app/dispatch.ex",
          "line" => 9
        },
        %{
          "caller_module" => "MyApp.Dispatch",
          "caller_function" => "run_known",
          "caller_arity" => 1,
          "kind" => "call",
          "path" => "lib/my_app/dispatch.ex",
          "line" => 4
        },
        %{
          "caller_module" => "MyAppWeb.OrderController",
          "caller_function" => "index",
          "caller_arity" => 2,
          "kind" => "call",
          "path" => "lib/my_app_web/order_controller.ex",
          "line" => 4
        }
      ]
    )

    ask!(
      out,
      "What does MyAppWeb.OrderController.index/2 call? (conn.assigns.user_id is field access, not a call)",
      """
      SELECT callee_module, callee_function, callee_arity, line FROM function_calls
      WHERE caller_module = 'MyAppWeb.OrderController' AND caller_function = 'index' AND caller_arity = 2
      ORDER BY line
      """,
      [
        %{
          "callee_module" => "MyApp.Orders",
          "callee_function" => "list_orders",
          "callee_arity" => 1,
          "line" => 4
        },
        %{
          "callee_module" => "Phoenix.Controller",
          "callee_function" => "render",
          "callee_arity" => 3,
          "line" => 5
        }
      ]
    )

    ask!(
      out,
      "Blast radius: what transitively calls MyApp.Orders.query/1?",
      """
      WITH RECURSIVE up(module, function, arity) AS (
        SELECT 'MyApp.Orders', 'query', 1
        UNION
        SELECT c.caller_module, c.caller_function, c.caller_arity
        FROM function_calls c JOIN up
          ON c.callee_module = up.module AND c.callee_function = up.function AND c.callee_arity = up.arity
      )
      SELECT * FROM up ORDER BY module, function
      """,
      [
        %{"module" => "MyApp.Dispatch", "function" => "captures", "arity" => 0},
        %{"module" => "MyApp.Dispatch", "function" => "run_known", "arity" => 1},
        %{"module" => "MyApp.Orders", "function" => "list_orders", "arity" => 1},
        %{"module" => "MyApp.Orders", "function" => "query", "arity" => 1},
        %{"module" => "MyAppWeb.OrderController", "function" => "index", "arity" => 2}
      ]
    )

    ask!(
      out,
      "Which declared public functions does nothing call? (callback implementations excluded; a candidate list, not a verdict)",
      """
      SELECT f.module, f.function, f.arity FROM functions f
      WHERE f.visibility = 'public' AND NOT f.is_generated
        AND NOT EXISTS (SELECT 1 FROM function_calls c
          WHERE c.callee_module = f.module AND c.callee_function = f.function AND c.callee_arity = f.arity)
        AND NOT EXISTS (SELECT 1 FROM callback_impls i
          WHERE i.module = f.module AND i.function = f.function AND i.arity = f.arity)
        AND f.module IN ('MyApp.Orders', 'MyApp.Repo', 'MyAppWeb.OrderController', 'MyApp.Workers.Mailer')
      ORDER BY ALL
      """,
      [%{"module" => "MyAppWeb.OrderController", "function" => "index", "arity" => 2}]
    )

    say(
      "index/2 is a Phoenix action: the router calls it at runtime, which is why it is a candidate only.\n"
    )

    ask!(
      out,
      "Which modules implement Oban.Worker?",
      "SELECT module FROM behaviours WHERE behaviour = 'Oban.Worker'",
      [
        %{"module" => "MyApp.Workers.Mailer"}
      ]
    )

    ask!(
      out,
      "What is the Oban.Worker contract, and which function fulfils it?",
      """
      SELECT c.function, c.arity, c.is_optional, i.module AS implemented_by
      FROM callbacks c LEFT JOIN callback_impls i USING (behaviour, function, arity)
      WHERE c.behaviour = 'Oban.Worker' ORDER BY c.function
      """,
      [
        %{
          "function" => "perform",
          "arity" => 1,
          "is_optional" => false,
          "implemented_by" => "MyApp.Workers.Mailer"
        },
        %{"function" => "timeout", "arity" => 1, "is_optional" => true, "implemented_by" => nil}
      ]
    )

    ask!(
      out,
      "What table does MyApp.Orders.Order map to, with which fields?",
      """
      SELECT s.source_table, f.field, f.type, f.is_primary_key
      FROM ecto_schemas s JOIN ecto_fields f USING (module)
      WHERE module = 'MyApp.Orders.Order'
      """,
      [
        %{"source_table" => "orders", "field" => "id", "type" => "id", "is_primary_key" => true},
        %{
          "source_table" => "orders",
          "field" => "total",
          "type" => "decimal",
          "is_primary_key" => false
        },
        %{
          "source_table" => "orders",
          "field" => "status",
          "type" => "Ecto.Enum",
          "is_primary_key" => false
        },
        %{
          "source_table" => "orders",
          "field" => "tags",
          "type" => "{:array, :string}",
          "is_primary_key" => false
        },
        %{
          "source_table" => "orders",
          "field" => "user_id",
          "type" => "id",
          "is_primary_key" => false
        },
        %{
          "source_table" => "orders",
          "field" => "address",
          "type" => "Ecto.Embedded",
          "is_primary_key" => false
        },
        %{
          "source_table" => "orders",
          "field" => "inserted_at",
          "type" => "naive_datetime",
          "is_primary_key" => false
        },
        %{
          "source_table" => "orders",
          "field" => "updated_at",
          "type" => "naive_datetime",
          "is_primary_key" => false
        }
      ]
    )

    ask!(
      out,
      "Which schemas point at MyApp.Accounts.User?",
      """
      SELECT module, name, kind FROM ecto_assocs WHERE related_module = 'MyApp.Accounts.User'
      """,
      [%{"module" => "MyApp.Orders.Order", "name" => "user", "kind" => "belongs_to"}]
    )

    ask!(
      out,
      "Where might the answer to 'who calls X' be incomplete? (callee module only known at runtime)",
      "SELECT caller_module, caller_function, callee_function, callee_arity, line FROM dynamic_function_calls ORDER BY ALL",
      [
        %{
          "caller_module" => "MyApp.Describable",
          "caller_function" => "describe",
          "callee_function" => "describe",
          "callee_arity" => 1,
          "line" => 2
        },
        %{
          "caller_module" => "MyApp.Dispatch",
          "caller_function" => "run",
          "callee_function" => "handle",
          "callee_arity" => nil,
          "line" => 2
        },
        %{
          "caller_module" => "MyApp.Dispatch",
          "caller_function" => "via_variable",
          "callee_function" => "handle",
          "callee_arity" => 1,
          "line" => 6
        },
        %{
          "caller_module" => "MyAppWeb",
          "caller_function" => "MACRO-__using__",
          "callee_function" => nil,
          "callee_arity" => 0,
          "line" => 11
        }
      ]
    )

    ask!(
      out,
      "Which dependency functions does the app use, and how often?",
      """
      SELECT e.module, e.function, e.arity, count(*) AS calls
      FROM external_functions e JOIN function_calls c
        ON c.callee_module = e.module AND c.callee_function = e.function AND c.callee_arity = e.arity
      WHERE e.module IN ('Phoenix.Controller', 'Oban.Worker', 'String')
      GROUP BY ALL ORDER BY ALL
      """,
      [
        %{"module" => "Phoenix.Controller", "function" => "render", "arity" => 3, "calls" => 1},
        %{"module" => "String", "function" => "upcase", "arity" => 1, "calls" => 1}
      ]
    )

    :ok
  end

  # -- 5. Compiler rules ------------------------------------------------------

  @spec compiler_rules(out :: Path.t()) :: :ok
  defp compiler_rules(out) do
    section("5. Compiler rules behind the answers")

    say("Facts come from the compiled BEAMs, so names and arities are the compiled ones.\n")

    ask!(
      out,
      "Macros keep their compiled name and arity: defmacro square(size) is MACRO-square/2.",
      "SELECT function, arity, visibility FROM functions WHERE module = 'MyApp.Shapes' AND function LIKE 'MACRO-%'",
      [%{"function" => "MACRO-square", "arity" => 2, "visibility" => "public"}]
    )

    ask!(
      out,
      "A default argument compiles to two arities with one range; the shorter one calls the longer.",
      """
      SELECT f.arity, f.start_line, f.end_line, c.callee_arity AS calls_arity
      FROM functions f LEFT JOIN function_calls c
        ON c.caller_module = f.module AND c.caller_function = f.function AND c.caller_arity = f.arity AND c.callee_function = 'area'
      WHERE f.module = 'MyApp.Shapes' AND f.function = 'area' ORDER BY f.arity
      """,
      [
        %{"arity" => 1, "start_line" => 4, "end_line" => 6, "calls_arity" => 2},
        %{"arity" => 2, "start_line" => 4, "end_line" => 6, "calls_arity" => nil}
      ]
    )

    source_lines("lib/my_app/shapes.ex", 4, 6)

    ask!(
      out,
      "Functions injected by `use` are generated and located at the use line; code from `quote location: :keep` is located where the quote is written.",
      """
      SELECT 'function' AS what, path, start_line AS line FROM functions
      WHERE module = 'MyAppWeb.OrderController' AND function = 'controller?'
      UNION ALL
      SELECT 'its call to Repo.all', path, line FROM function_calls
      WHERE caller_module = 'MyAppWeb.OrderController' AND caller_function = 'controller?' AND callee_function = 'all'
      ORDER BY what
      """,
      [
        %{"what" => "function", "path" => "lib/my_app_web/order_controller.ex", "line" => 2},
        %{"what" => "its call to Repo.all", "path" => "lib/my_app_web.ex", "line" => 6}
      ]
    )

    ask!(
      out,
      "A catch-all clause added by @before_compile does not stretch the declared function's range.",
      "SELECT start_line, end_line, is_generated FROM functions WHERE module = 'MyApp.Handler' AND function = 'handle'",
      [%{"start_line" => 4, "end_line" => 7, "is_generated" => false}]
    )

    ask!(
      out,
      "defoverridable renames the original; super(...) is a call to it.",
      """
      SELECT caller_function, callee_function FROM function_calls
      WHERE caller_module = 'MyApp.Handler' AND caller_function = 'greet'
      """,
      [%{"caller_function" => "greet", "callee_function" => "greet (overridable 1)"}]
    )

    ask!(
      out,
      "A module a dependency defines on the app's behalf (like NimbleCSV.define/2) is generated, with no location.",
      "SELECT module, is_generated, path FROM modules WHERE module = 'MyApp.Csv'",
      [%{"module" => "MyApp.Csv", "is_generated" => true, "path" => nil}]
    )

    ask!(
      out,
      "Protocols are behaviours: a defimpl declares its protocol, whose callbacks are the protocol functions.",
      """
      SELECT b.module, b.behaviour, c.function, c.arity
      FROM behaviours b JOIN callbacks c USING (behaviour) WHERE b.behaviour = 'MyApp.Describable'
      """,
      [
        %{
          "module" => "MyApp.Describable.MyApp.Shapes",
          "behaviour" => "MyApp.Describable",
          "function" => "describe",
          "arity" => 1
        }
      ]
    )

    ask!(
      out,
      "Operators and guards compile to Erlang calls; Elixir also inlines some stdlib calls, e.g. Map.to_list/1 is recorded as maps.to_list/1.",
      """
      SELECT callee_module, callee_function, callee_arity FROM function_calls
      WHERE caller_module = 'MyApp.Dispatch' AND caller_function = 'local' ORDER BY callee_function
      """,
      [
        %{"callee_module" => "erlang", "callee_function" => "+", "callee_arity" => 2},
        %{"callee_module" => "erlang", "callee_function" => "is_integer", "callee_arity" => 1}
      ]
    )

    source_lines("lib/my_app/dispatch.ex", 14, 14)
    :ok
  end

  # -- 6. Your own app --------------------------------------------------------

  @spec real_app(app :: Path.t(), ebin :: Path.t() | nil) :: :ok
  defp real_app(app, ebin) do
    section("6. Your app: #{app}")
    app = Path.expand(app)
    ebin = ebin || app_ebin(app)
    out = Path.join(System.tmp_dir!(), "faction-tour-app-#{System.unique_integer([:positive])}")

    say("faction --root #{app} --out #{out} --deps #{app}/_build/dev/lib #{ebin}\n")

    {micros, summary} =
      :timer.tc(fn ->
        Faction.run([ebin], root: app, out: out, deps: [Path.join(app, "_build/dev/lib")])
      end)

    say("#{summary.beams} BEAMs in #{Float.round(micros / 1_000_000, 2)} s")
    say("Rows: #{inspect(summary.rows)}")

    say(
      "Skipped: #{length(summary.skipped)}, behaviours without a BEAM: #{inspect(summary.missing_behaviours)}\n"
    )

    {_output, 0} =
      System.cmd("duckdb", ["faction.duckdb", "-f", "schema.sql"],
        cd: out,
        stderr_to_stdout: true
      )

    subsection("Most-called application functions")

    show(out, """
    SELECT c.callee_module AS module, c.callee_function AS function, c.callee_arity AS arity, count(*) AS call_sites
    FROM function_calls c JOIN functions f
      ON f.module = c.callee_module AND f.function = c.callee_function AND f.arity = c.callee_arity
    WHERE NOT f.is_generated
    GROUP BY ALL ORDER BY call_sites DESC LIMIT 10
    """)

    subsection("Modules with the most distinct callers (fan-in)")

    show(out, """
    SELECT callee_module AS module, count(DISTINCT caller_module) AS calling_modules
    FROM function_calls WHERE callee_module IN (SELECT module FROM modules) AND callee_module <> caller_module
    GROUP BY ALL ORDER BY calling_modules DESC LIMIT 10
    """)

    say("Explore it: cd #{out} && duckdb faction.duckdb")
  end

  @spec app_ebin(app :: Path.t()) :: Path.t()
  defp app_ebin(app) do
    case Regex.run(~r/\bapp:\s*:(\w+)/, File.read!(Path.join(app, "mix.exs"))) do
      [_match, name] -> Path.join(app, "_build/dev/lib/#{name}/ebin")
      nil -> raise "could not find `app:` in #{app}/mix.exs; pass --ebin"
    end
  end

  # -- Helpers ----------------------------------------------------------------

  @spec ask!(out :: Path.t(), question :: String.t(), sql :: String.t(), expected :: list(map())) ::
          :ok
  defp ask!(out, question, sql, expected) do
    say("Q: " <> question)
    say(indent(String.trim(sql)) <> "\n")
    show(out, sql)
    actual = sql!(out, sql)

    check!(question, actual == expected, fn ->
      "expected:\n#{inspect(expected, pretty: true)}\ngot:\n#{inspect(actual, pretty: true)}"
    end)
  end

  @spec check!(label :: String.t(), passed? :: boolean(), details :: (-> String.t())) :: :ok
  defp check!(label, passed?, details \\ fn -> "" end) do
    if passed? do
      Process.put(:checks, Process.get(:checks) + 1)
      say("  ✓ " <> label <> "\n")
    else
      IO.puts(:stderr, "\n✗ Check failed: #{label}\n#{details.()}")
      System.halt(1)
    end
  end

  @spec sql!(out :: Path.t(), sql :: String.t()) :: list(map())
  defp sql!(out, sql) do
    case duckdb(out, ["-json"], sql) do
      "" -> []
      json -> JSON.decode!(json)
    end
  end

  @spec show(out :: Path.t(), sql :: String.t()) :: :ok
  defp show(out, sql), do: say(duckdb(out, ["-box"], sql))

  @spec duckdb(out :: Path.t(), flags :: list(String.t()), sql :: String.t()) :: String.t()
  defp duckdb(out, flags, sql) do
    case System.cmd("duckdb", flags ++ ["faction.duckdb", sql], cd: out, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "duckdb exited #{status}: #{output}\nSQL: #{sql}"
    end
  end

  @spec source_lines(path :: String.t(), first :: pos_integer(), last :: pos_integer()) :: :ok
  defp source_lines(path, first, last) do
    lines =
      Fixture.root()
      |> Path.join(path)
      |> File.read!()
      |> String.split("\n")
      |> Enum.slice((first - 1)..(last - 1)//1)
      |> Enum.with_index(first)
      |> Enum.map_join("\n", fn {line, number} -> "    #{path}:#{number}  #{line}" end)

    say(lines <> "\n")
  end

  @spec section(title :: String.t()) :: :ok
  defp section(title) do
    heading = IO.ANSI.format([:bright, "━━ #{title} ", String.duplicate("━", 60)])
    say("\n" <> IO.iodata_to_binary(heading))
  end

  @spec subsection(title :: String.t()) :: :ok
  defp subsection(title), do: say(IO.iodata_to_binary(IO.ANSI.format([:bright, "── #{title}"])))

  @spec indent(text :: String.t()) :: String.t()
  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))

  @spec say(text :: String.t()) :: :ok
  defp say(text) do
    if System.get_env("TOUR_QUIET") != "1", do: IO.puts(text)
    :ok
  end
end

Faction.Tour.main(System.argv())
