defmodule Faction.Schema do
  @moduledoc """
  Renders `schema.sql`, which loads the JSONL relations into a DuckDB file.
  """

  alias Faction.Relation

  @doc "The contents of `schema.sql`."
  @spec render() :: String.t()
  def render do
    IO.iodata_to_binary([
      "-- Loads Faction's JSONL relations into DuckDB. Run from this directory:\n",
      "--   duckdb faction.duckdb < schema.sql\n",
      "-- Then query faction.duckdb. DESCRIBE a table or read duckdb_columns() for column comments.\n",
      Enum.map(Relation.all(), &table/1),
      Enum.map(Relation.views(), &view/1)
    ])
  end

  @spec table(relation :: Relation.t()) :: iodata()
  defp table(%Relation{} = relation) do
    %Relation{name: name, comment: comment, columns: columns} = relation

    json_columns =
      Enum.map_join(columns, ", ", fn {column, type, _comment} ->
        "#{column}: #{quote_string(json_type(type))}"
      end)

    [
      "\nCREATE OR REPLACE TABLE #{name} (\n",
      Enum.map_join(columns, ",\n", fn {column, type, _comment} -> "  #{column} #{type}" end),
      "\n);\n",
      "INSERT INTO #{name} SELECT * FROM read_json(#{quote_string(Relation.file_name(relation))}, ",
      "format = 'newline_delimited', columns = {#{json_columns}});\n",
      "COMMENT ON TABLE #{name} IS #{quote_string(comment)};\n",
      Enum.map(columns, fn {column, _type, column_comment} ->
        "COMMENT ON COLUMN #{name}.#{column} IS #{quote_string(column_comment)};\n"
      end)
    ]
  end

  @spec view(view :: Relation.view()) :: iodata()
  defp view(view) do
    [
      "\nCREATE OR REPLACE VIEW #{view.name} AS\n",
      String.trim_trailing(view.sql),
      ";\n",
      "COMMENT ON VIEW #{view.name} IS #{quote_string(view.comment)};\n",
      Enum.map(view.columns, fn {column, comment} ->
        "COMMENT ON COLUMN #{view.name}.#{column} IS #{quote_string(comment)};\n"
      end)
    ]
  end

  @spec json_type(type :: String.t()) :: String.t()
  defp json_type(type), do: String.replace_suffix(type, " NOT NULL", "")

  @spec quote_string(value :: String.t()) :: String.t()
  defp quote_string(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
