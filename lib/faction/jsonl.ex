defmodule Faction.JSONL do
  @moduledoc """
  Encodes rows as JSON lines with keys in the relation's column order.
  """

  alias Faction.Relation

  @doc "Encodes one row as a JSON line, keys in column order, ending with a newline."
  @spec encode(relation :: Relation.t(), row :: map()) :: iodata()
  def encode(%Relation{} = relation, row) do
    fields =
      Enum.map_intersperse(relation.columns, ?,, fn {name, _type, _comment} ->
        [JSON.encode!(Atom.to_string(name)), ?:, JSON.encode!(Map.fetch!(row, name))]
      end)

    [?{, fields, ?}, ?\n]
  end
end
