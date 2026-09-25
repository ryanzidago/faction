defmodule Faction.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Faction.CLI
  alias Faction.Fixture

  @tag :tmp_dir
  test "extracts the given ebin directories and prints how to load them", %{tmp_dir: out} do
    output =
      capture_io(fn ->
        assert CLI.run([
                 "--root",
                 Fixture.root(),
                 "--out",
                 out,
                 "--deps",
                 Fixture.deps_ebin(),
                 Fixture.app_ebin()
               ]) == 0
      end)

    assert output =~ "20 BEAMs"
    assert output =~ "cd #{out} && duckdb faction.duckdb < schema.sql"
    assert output =~ ~s(duckdb #{out}/faction.duckdb "FROM faction_columns")
    assert File.exists?(Path.join(out, "schema.sql"))
  end

  test "without ebin directories it prints usage and fails" do
    assert capture_io(:stderr, fn -> assert CLI.run([]) == 1 end) =~ "usage: faction"
  end

  test "a missing ebin directory fails" do
    assert capture_io(:stderr, fn -> assert CLI.run(["does/not/exist"]) == 1 end) =~
             "not a directory"
  end
end
