defmodule Faction.RawFile do
  @moduledoc """
  Reads files in raw mode, bypassing the Erlang file server so parallel
  extraction workers do not serialize on it.
  """

  @chunk_size 1_048_576

  @doc "Reads the whole file at `path`."
  @spec read(path :: Path.t()) :: {:ok, binary()} | {:error, File.posix() | :badarg | :terminated}
  def read(path) do
    with {:ok, device} <- :file.open(path, [:raw, :binary, :read]) do
      try do
        read_all(device, [])
      after
        :file.close(device)
      end
    end
  end

  @spec read_all(device :: :file.io_device(), acc :: iodata()) ::
          {:ok, binary()} | {:error, File.posix() | :badarg | :terminated}
  defp read_all(device, acc) do
    case :file.read(device, @chunk_size) do
      {:ok, data} -> read_all(device, [acc | data])
      :eof -> {:ok, IO.iodata_to_binary(acc)}
      {:error, reason} -> {:error, reason}
    end
  end
end
