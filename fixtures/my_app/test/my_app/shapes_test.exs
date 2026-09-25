defmodule MyApp.ShapesTest do
  use ExUnit.Case, async: true

  defmodule Square do
    def sides, do: 4
  end

  test "a square's area scales" do
    assert MyApp.Shapes.area(%MyApp.Shapes{sides: Square.sides()}, 2) == 8
  end
end
