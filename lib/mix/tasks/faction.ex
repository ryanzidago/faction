defmodule Mix.Tasks.Faction do
  @shortdoc "Extracts BEAM files into JSONL relations for DuckDB"
  @moduledoc """
  Extracts compiled BEAM files into JSONL relations and a `schema.sql`.

      mix faction [--root DIR] [--out DIR] EBIN_DIR...

  See `Faction.CLI` for the options.
  """

  use Mix.Task

  @impl Mix.Task
  @spec run(argv :: list(String.t())) :: :ok
  def run(argv) do
    case Faction.CLI.run(argv) do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
