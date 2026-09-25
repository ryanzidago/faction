defmodule Faction.Literal do
  @moduledoc """
  Decodes literal terms from clause bodies in a module's debug info.

  Nothing is evaluated: only atoms, numbers, strings, lists, tuples, maps and
  structs decode; any other expression (a call, a variable, a capture) makes
  the whole term fail to decode.
  """

  @doc "The term an AST literal stands for, or `:error` when it is not a literal."
  @spec literal(ast :: Macro.t()) :: {:ok, term()} | :error
  def literal(ast) when is_atom(ast) or is_number(ast) or is_binary(ast), do: {:ok, ast}
  def literal(list) when is_list(list), do: literal_list(list)

  def literal({left, right}) do
    with {:ok, left} <- literal(left), {:ok, right} <- literal(right), do: {:ok, {left, right}}
  end

  def literal({:{}, _meta, elements}) when is_list(elements) do
    with {:ok, elements} <- literal_list(elements), do: {:ok, List.to_tuple(elements)}
  end

  def literal({:%{}, _meta, pairs}) when is_list(pairs) do
    with {:ok, pairs} <- literal_list(pairs), do: {:ok, Map.new(pairs)}
  end

  def literal({:%, _meta, [struct, {:%{}, _map_meta, _pairs} = map]}) when is_atom(struct) do
    with {:ok, map} <- literal(map), do: {:ok, Map.put(map, :__struct__, struct)}
  end

  def literal(_ast), do: :error

  @spec literal_list(list :: list(Macro.t())) :: {:ok, list(term())} | :error
  defp literal_list(list) do
    decoded =
      Enum.reduce_while(list, {:ok, []}, fn element, {:ok, acc} ->
        case literal(element) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          :error -> {:halt, :error}
        end
      end)

    with {:ok, acc} <- decoded, do: {:ok, Enum.reverse(acc)}
  end
end
