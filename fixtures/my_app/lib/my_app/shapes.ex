defmodule MyApp.Shapes do
  defstruct [:sides]

  def area(shape, scale \\ 1)
  def area(%__MODULE__{sides: 4}, scale), do: 4 * scale
  def area(%__MODULE__{}, scale), do: helper(scale)

  defmacro square(size) do
    quote do: unquote(size) * unquote(size)
  end

  defp helper(x),
    do: x
end

defimpl MyApp.Describable, for: MyApp.Shapes do
  def describe(shape), do: "shape with #{shape.sides} sides"
end
