defmodule Faction do
  @moduledoc """
  Static analysis of compiled BEAM files into flat JSONL relations.

  See `PRINCIPLES.md` for the design.
  """

  alias Faction.Beam
  alias Faction.Behaviours
  alias Faction.Extract
  alias Faction.JSONL
  alias Faction.Relation
  alias Faction.Schema

  @typedoc "What a run wrote, and what it skipped with the reason."
  @type summary() :: %{
          beams: non_neg_integer(),
          rows: %{atom() => non_neg_integer()},
          skipped: list({Path.t(), String.t()}),
          missing_behaviours: list(String.t())
        }

  @typedoc """
  * `:root` - the repository root (default: current directory). Source paths
    are reported relative to it; source outside it is not reported.
  * `:out` - the output directory (default: `out`).
  * `:deps` - directories holding dependency BEAMs, used only to read the
    callbacks of behaviours. Each is an ebin directory, or a directory of
    `*/ebin` directories such as `_build/dev/lib`.
  """
  @type opts() :: [root: Path.t(), out: Path.t(), deps: list(Path.t())]

  @typep devices() :: %{atom() => {Relation.t(), File.io_device()}}
  @typep encoded() :: {binary(), non_neg_integer()}

  @doc """
  Extracts every BEAM in `ebin_dirs` into JSONL relations and `schema.sql`.

  Every BEAM in `ebin_dirs` is application code. BEAMs are extracted in
  parallel and written in sorted path order. A second pass reads the callbacks
  of the behaviours the application declares or defines.
  """
  @spec run(ebin_dirs :: list(Path.t()), opts :: opts()) :: summary()
  def run(ebin_dirs, opts \\ []) do
    root = Keyword.get(opts, :root, ".")
    out = Keyword.get(opts, :out, "out")
    ebin_dirs = Enum.map(ebin_dirs, &Path.expand/1)
    dep_ebin_dirs = dep_ebin_dirs(Keyword.get(opts, :deps, []), ebin_dirs)

    File.mkdir_p!(out)
    File.write!(Path.join(out, "schema.sql"), Schema.render())

    devices =
      Map.new(Relation.all(), fn relation ->
        path = Path.join(out, Relation.file_name(relation))
        {relation.name, {relation, File.open!(path, [:write, :binary, :delayed_write, :raw])}}
      end)

    try do
      {summary, behaviours} = extract_beams(ebin_dirs, root, devices)
      write_callbacks(behaviours, ebin_dirs ++ dep_ebin_dirs, devices, summary)
    after
      Enum.each(devices, fn {_name, {_relation, device}} -> File.close(device) end)
    end
  end

  @spec extract_beams(ebin_dirs :: list(Path.t()), root :: Path.t(), devices :: devices()) ::
          {summary(), MapSet.t(module())}
  defp extract_beams(ebin_dirs, root, devices) do
    initial = %{
      beams: 0,
      rows: Map.new(Relation.all(), &{&1.name, 0}),
      skipped: [],
      missing_behaviours: []
    }

    ebin_dirs
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.beam")))
    |> Enum.sort()
    # Ordered results wait on the slowest BEAM in flight; twice the schedulers
    # keeps the cores busy (26,900 BEAMs: 15.6s at 1x, 6.8s at 2x, same memory).
    |> Task.async_stream(&{&1, extract_encoded(&1, root)},
      ordered: true,
      timeout: :infinity,
      max_concurrency: System.schedulers_online() * 2
    )
    |> Enum.reduce({initial, MapSet.new()}, fn
      {:ok, {beam, {:error, reason}}}, {summary, behaviours} ->
        {%{summary | skipped: summary.skipped ++ [{beam, reason}]}, behaviours}

      {:ok, {_beam, {:ok, rows, beam_behaviours}}}, {summary, behaviours} ->
        summary =
          Enum.reduce(rows, summary, fn {name, encoded}, summary ->
            write(name, encoded, devices, summary)
          end)

        {%{summary | beams: summary.beams + 1},
         MapSet.union(behaviours, MapSet.new(beam_behaviours))}
    end)
  end

  # The second pass: one BEAM read per distinct behaviour, in sorted order.
  @spec write_callbacks(
          behaviours :: MapSet.t(module()),
          search_dirs :: list(Path.t()),
          devices :: devices(),
          summary :: summary()
        ) :: summary()
  defp write_callbacks(behaviours, search_dirs, devices, summary) do
    behaviours
    |> Enum.sort()
    |> Enum.reduce(summary, fn behaviour, summary ->
      with {:ok, beam} <- Behaviours.read(behaviour, search_dirs),
           {:ok, rows} <- Behaviours.callback_rows(behaviour, beam) do
        write(:callbacks, encode(Relation.fetch!(:callbacks), rows), devices, summary)
      else
        _missing ->
          missing = summary.missing_behaviours ++ [Beam.module_name(behaviour)]
          %{summary | missing_behaviours: missing}
      end
    end)
  end

  @spec write(name :: atom(), encoded :: encoded(), devices :: devices(), summary :: summary()) ::
          summary()
  defp write(name, {binary, count}, devices, summary) do
    {_relation, device} = Map.fetch!(devices, name)
    IO.binwrite(device, binary)
    %{summary | rows: Map.update!(summary.rows, name, &(&1 + count))}
  end

  # Runs in the extraction workers, so JSON encoding is parallel too; the
  # writer only appends the encoded binaries in order.
  @spec extract_encoded(path :: Path.t(), root :: Path.t()) ::
          {:ok, list({atom(), encoded()}), list(module())} | {:error, String.t()}
  defp extract_encoded(path, root) do
    with {:ok, rows, behaviours} <- Extract.rows(path, root) do
      encoded =
        for relation <- Relation.all(),
            do: {relation.name, encode(relation, Map.get(rows, relation.name, []))}

      {:ok, encoded, behaviours}
    end
  end

  @spec encode(relation :: Relation.t(), rows :: list(map())) :: encoded()
  defp encode(relation, rows) do
    {IO.iodata_to_binary(Enum.map(rows, &JSONL.encode(relation, &1))), Enum.count(rows)}
  end

  @spec dep_ebin_dirs(deps :: list(Path.t()), ebin_dirs :: list(Path.t())) :: list(Path.t())
  defp dep_ebin_dirs(deps, ebin_dirs) do
    deps
    |> Enum.map(&Path.expand/1)
    |> Enum.flat_map(fn dir ->
      if Enum.empty?(Path.wildcard(Path.join(dir, "*.beam"))) do
        dir
        |> Path.join("*/ebin")
        |> Path.wildcard()
        |> Enum.sort()
      else
        [dir]
      end
    end)
    |> Enum.reject(&(&1 in ebin_dirs))
  end
end
