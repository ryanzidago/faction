defmodule Faction.Schema do
  @moduledoc """
  Renders `schema.sql`, which loads the JSONL relations into a DuckDB file.
  """

  alias Faction.Relation

  @columns_view :faction_columns

  @doc "The contents of `schema.sql`."
  @spec render() :: String.t()
  def render do
    IO.iodata_to_binary([
      "-- Loads Faction's JSONL relations into DuckDB with the duckdb CLI.\n",
      "-- The JSONL paths are relative, so run it from this directory:\n",
      "--   duckdb faction.duckdb < schema.sql\n",
      "-- Then query faction.duckdb. Start with: FROM #{@columns_view}\n",
      "-- (every table and view column with its type and comment).\n",
      ".bail on\n",
      "SET VARIABLE faction_guard = (SELECT error(",
      quote_string(
        "schema.sql reads its JSONL files relative to the current directory. " <>
          "Run it from its own directory: cd <that directory> && duckdb faction.duckdb < schema.sql"
      ),
      ") WHERE NOT EXISTS (FROM glob(#{quote_string(Relation.file_name(Relation.fetch!(:modules)))})));\n",
      Enum.map(Relation.all(), &table/1),
      Enum.map(Relation.views(), &view/1),
      columns_view()
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

  @spec columns_view() :: iodata()
  defp columns_view do
    names = Enum.map(Relation.all(), & &1.name) ++ Enum.map(Relation.views(), & &1.name)

    view(%{
      name: @columns_view,
      comment:
        "Faction's schema: every column of its tables and views with its type and comment. Start here.",
      columns: [
        {:table_name, "Table or view, e.g. modules, function_calls, external_functions."},
        {:column_name, "Column name."},
        {:data_type, "DuckDB type of the column."},
        {:comment, "What the column holds and what it joins."}
      ],
      sql: """
      SELECT table_name, column_name, data_type, comment
      FROM duckdb_columns()
      WHERE database_name = current_database() AND schema_name = 'main'
        AND table_name IN (#{Enum.map_join(names ++ [@columns_view], ", ", &quote_string(to_string(&1)))})
      ORDER BY table_name, column_index
      """
    })
  end

  @spec json_type(type :: String.t()) :: String.t()
  defp json_type(type), do: String.replace_suffix(type, " NOT NULL", "")

  @spec quote_string(value :: String.t()) :: String.t()
  defp quote_string(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
