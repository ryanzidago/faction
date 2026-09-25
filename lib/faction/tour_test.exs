defmodule Faction.TourTest do
  # Sync: the tour recompiles the fixture that async tests read, and ExUnit
  # runs sync modules after all async ones.
  use ExUnit.Case, async: false

  @tag timeout: 300_000
  test "the guided tour (guides/tour.exs) passes every check" do
    {output, status} =
      System.cmd("mix", ["run", "guides/tour.exs"],
        env: [{"MIX_ENV", "test"}, {"TOUR_QUIET", "1"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
