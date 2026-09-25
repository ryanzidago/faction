defmodule Faction do
  @moduledoc """
  Static analysis of compiled BEAM files into flat JSONL relations.

  See `PRINCIPLES.md` for the design.
  """

  @doc "Returns the Faction version."
  @spec version() :: String.t()
  def version, do: "0.1.0"
end
