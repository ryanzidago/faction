defmodule FactionTest do
  use ExUnit.Case, async: true

  alias Faction.Fixture

  @relations [
    "modules",
    "functions",
    "function_calls",
    "dynamic_function_calls",
    "module_references",
    "behaviours",
    "callbacks",
    "ecto_schemas",
    "ecto_fields",
    "ecto_assocs"
  ]

  @tag :tmp_dir
  test "the fixture's relations match the expected output", %{tmp_dir: out} do
    Faction.run([Fixture.app_ebin()], root: Fixture.root(), out: out, deps: [Fixture.deps_ebin()])

    for relation <- @relations do
      assert File.read!(Path.join(out, relation <> ".jsonl")) ==
               File.read!(Path.join(Fixture.expected_dir(), relation <> ".jsonl")),
             "#{relation}.jsonl differs from fixtures/expected"
    end
  end

  @tag :tmp_dir
  test "two runs over the same BEAMs write identical files", %{tmp_dir: tmp_dir} do
    first = Path.join(tmp_dir, "first")
    second = Path.join(tmp_dir, "second")

    Faction.run([Fixture.app_ebin()],
      root: Fixture.root(),
      out: first,
      deps: [Fixture.deps_ebin()]
    )

    Faction.run([Fixture.app_ebin()],
      root: Fixture.root(),
      out: second,
      deps: [Fixture.deps_ebin()]
    )

    for file <- File.ls!(first) do
      assert File.read!(Path.join(first, file)) == File.read!(Path.join(second, file))
    end
  end

  @tag :tmp_dir
  test "source outside the repository root is not reported", %{tmp_dir: out} do
    Faction.run([Fixture.app_ebin()], root: Path.join(out, "elsewhere"), out: out)

    rows = rows(out, "functions")

    assert Enum.all?(rows, &is_nil(&1["path"]))
    assert Enum.all?(rows, &is_nil(&1["start_line"]))
  end

  @tag :tmp_dir
  test "dependency source under the root's deps/ is not reported as application source", %{
    tmp_dir: out
  } do
    # With fixtures/ as the root, the stand-in dependencies live in deps/.
    Faction.run([Fixture.app_ebin()], root: Path.dirname(Fixture.root()), out: out)

    modules = rows(out, "modules")

    assert %{"is_generated" => true, "path" => nil, "start_line" => nil} =
             Enum.find(modules, &(&1["module"] == "MyApp.Csv"))

    assert %{"module" => "MyApp.Orders", "path" => "my_app/lib/my_app/orders.ex"} =
             Enum.find(modules, &(&1["module"] == "MyApp.Orders"))
  end

  @tag :tmp_dir
  test "BEAMs without Elixir debug info are skipped and reported", %{tmp_dir: out} do
    ebin = Path.join(out, "ebin")
    File.mkdir_p!(ebin)
    File.write!(Path.join(ebin, "broken.beam"), "not a beam")

    summary = Faction.run([ebin], root: Fixture.root(), out: out)

    assert %{beams: 0, skipped: [{skipped, _reason}]} = summary
    assert Path.basename(skipped) == "broken.beam"
    assert File.read!(Path.join(out, "modules.jsonl")) == ""
  end

  @tag :tmp_dir
  test "schema.sql loads the relations into DuckDB with every column commented", %{tmp_dir: out} do
    load!(out)

    assert duckdb(
             out,
             "SELECT count(*) AS n FROM duckdb_columns() WHERE comment IS NULL AND NOT internal"
           ) ==
             [%{"n" => 0}]

    assert duckdb(
             out,
             "SELECT count(*) AS n FROM duckdb_views() WHERE comment IS NULL AND NOT internal"
           ) ==
             [%{"n" => 0}]
  end

  @tag :tmp_dir
  test "faction_columns lists only Faction's tables and views", %{tmp_dir: out} do
    load!(out)

    names = Enum.map(Faction.Relation.all() ++ Faction.Relation.views(), &to_string(&1.name))

    faction_columns =
      duckdb(out, "FROM faction_columns WHERE table_name <> 'faction_columns'")

    assert faction_columns ==
             duckdb(out, """
             SELECT table_name, column_name, data_type, comment FROM duckdb_columns()
             WHERE NOT internal AND table_name <> 'faction_columns'
             ORDER BY table_name, column_index
             """)

    assert Enum.sort(Enum.uniq(Enum.map(faction_columns, & &1["table_name"]))) == Enum.sort(names)

    [%{"n" => catalog}] = duckdb(out, "SELECT count(*) AS n FROM duckdb_columns()")
    assert Enum.count(faction_columns) * 5 < catalog
  end

  @tag :tmp_dir
  test "schema.sql run from another directory stops with one clear error", %{tmp_dir: tmp_dir} do
    out = Path.join(tmp_dir, "out")
    elsewhere = Path.join(tmp_dir, "elsewhere")
    File.mkdir_p!(elsewhere)
    Faction.run([Fixture.app_ebin()], root: Fixture.root(), out: out, deps: [Fixture.deps_ebin()])

    {output, status} =
      System.cmd("duckdb", ["x.duckdb", "-f", Path.join(out, "schema.sql")], cmd_opts(elsewhere))

    assert status != 0
    assert output =~ "Run it from its own directory"
    refute output =~ "No files found"
  end

  @tag :tmp_dir
  test "the example queries in PRINCIPLES.md answer on the fixture", %{tmp_dir: out} do
    load!(out)

    # Where is this function defined?
    assert duckdb(out, """
           SELECT path, start_line, end_line FROM functions
           WHERE module = 'MyApp.Orders' AND function = 'list_orders' AND arity = 1
           """) == [%{"path" => "lib/my_app/orders.ex", "start_line" => 2, "end_line" => 4}]

    # Which arities come from default arguments, and which arity do they default to?
    assert duckdb(out, """
           SELECT function, arity, defaults_to_arity FROM functions
           WHERE module = 'MyApp.Shapes' AND function IN ('area', 'helper', '__struct__', 'MACRO-square')
           ORDER BY function, arity
           """) == [
             %{"function" => "MACRO-square", "arity" => 2, "defaults_to_arity" => nil},
             %{"function" => "__struct__", "arity" => 0, "defaults_to_arity" => nil},
             %{"function" => "__struct__", "arity" => 1, "defaults_to_arity" => nil},
             %{"function" => "area", "arity" => 1, "defaults_to_arity" => 2},
             %{"function" => "area", "arity" => 2, "defaults_to_arity" => nil},
             %{"function" => "helper", "arity" => 1, "defaults_to_arity" => nil}
           ]

    # Who calls list_orders/1? The capture and the literal apply/3 count.
    assert duckdb(out, """
           SELECT caller_module, caller_function, caller_arity, kind, path, line
           FROM function_calls
           WHERE callee_module = 'MyApp.Orders' AND callee_function = 'list_orders' AND callee_arity = 1
           ORDER BY caller_module, caller_function
           """) == [
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

    # What does index/2 call? Field access (conn.assigns) is not a call.
    assert duckdb(out, """
           SELECT callee_module, callee_function, callee_arity, line
           FROM function_calls
           WHERE caller_module = 'MyAppWeb.OrderController' AND caller_function = 'index' AND caller_arity = 2
           ORDER BY line
           """) == [
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

    # Blast radius: everything that transitively calls query/1.
    assert duckdb(out, """
           WITH RECURSIVE up(module, function, arity) AS (
             SELECT 'MyApp.Orders', 'query', 1
             UNION
             SELECT c.caller_module, c.caller_function, c.caller_arity
             FROM function_calls c JOIN up
               ON c.callee_module = up.module AND c.callee_function = up.function AND c.callee_arity = up.arity
           )
           SELECT * FROM up ORDER BY module, function
           """) == [
             %{"module" => "MyApp.Dispatch", "function" => "captures", "arity" => 0},
             %{"module" => "MyApp.Dispatch", "function" => "run_known", "arity" => 1},
             %{"module" => "MyApp.Orders", "function" => "list_orders", "arity" => 1},
             %{"module" => "MyApp.Orders", "function" => "query", "arity" => 1},
             %{"module" => "MyAppWeb.OrderController", "function" => "index", "arity" => 2}
           ]

    # Where is MyApp.Orders.Order used as a value? A module that is only
    # called (MyApp.Repo) is not a reference.
    assert %{
             "caller_module" => "MyApp.Orders",
             "caller_function" => "query",
             "caller_arity" => 1,
             "path" => "lib/my_app/orders.ex",
             "line" => 6
           } in duckdb(out, """
           SELECT caller_module, caller_function, caller_arity, path, line
           FROM module_references
           WHERE referenced_module = 'MyApp.Orders.Order' AND caller_module <> referenced_module
           """)

    assert duckdb(
             out,
             "SELECT count(*) AS n FROM module_references WHERE referenced_module = 'MyApp.Repo'"
           ) == [%{"n" => 0}]

    # Public application functions that nothing calls (a candidate list).
    unused =
      duckdb(out, """
      SELECT f.module || '.' || f.function || '/' || f.arity AS mfa
      FROM functions f
      WHERE f.visibility = 'public' AND NOT f.is_generated
        AND NOT EXISTS (
          SELECT 1 FROM function_calls c
          WHERE c.callee_module = f.module AND c.callee_function = f.function AND c.callee_arity = f.arity)
      ORDER BY mfa
      """)

    assert %{"mfa" => "MyAppWeb.OrderController.index/2"} in unused
    refute %{"mfa" => "MyApp.Orders.list_orders/1"} in unused
    refute %{"mfa" => "MyApp.Repo.all/1"} in unused

    # Dependencies and stdlib appear only as callees.
    assert %{"module" => "Phoenix.Controller", "function" => "render", "arity" => 3} in duckdb(
             out,
             "SELECT module, function, arity FROM external_functions"
           )

    assert duckdb(
             out,
             "SELECT count(*) AS n FROM external_functions WHERE module = 'MyApp.Orders'"
           ) ==
             [%{"n" => 0}]
  end

  @spec rows(out :: Path.t(), relation :: String.t()) :: list(map())
  defp rows(out, relation) do
    out
    |> Path.join(relation <> ".jsonl")
    |> File.stream!()
    |> Enum.map(&JSON.decode!/1)
  end

  @spec load!(out :: Path.t()) :: :ok
  defp load!(out) do
    Faction.run([Fixture.app_ebin()], root: Fixture.root(), out: out, deps: [Fixture.deps_ebin()])
    {_output, 0} = System.cmd("duckdb", ["faction.duckdb", "-f", "schema.sql"], cmd_opts(out))
    :ok
  end

  @spec duckdb(dir :: Path.t(), sql :: String.t()) :: list(map())
  defp duckdb(dir, sql) do
    {output, 0} = System.cmd("duckdb", ["-json", "faction.duckdb", sql], cmd_opts(dir))

    if String.trim(output) == "" do
      []
    else
      JSON.decode!(output)
    end
  end

  @spec cmd_opts(dir :: Path.t()) :: keyword()
  defp cmd_opts(dir), do: [cd: dir, stderr_to_stdout: true, env: [{"HOME", dir}]]
end
