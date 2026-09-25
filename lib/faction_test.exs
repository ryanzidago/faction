defmodule FactionTest do
  use ExUnit.Case, async: true

  test "version/0 returns a version string" do
    assert Faction.version() == "0.1.0"
  end
end
