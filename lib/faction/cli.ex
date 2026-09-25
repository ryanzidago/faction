defmodule Faction.CLI do
  @moduledoc """
  Command line entry point, shared by `mix faction` and the escript.

      faction [--root DIR] [--out DIR] [--deps DIR]... EBIN_DIR...

  Every BEAM in each EBIN_DIR is treated as application code. `--root` is the
  repository root used for source paths (default: current directory). `--out`
  is where the JSONL relations and `schema.sql` are written (default: `out`).
  `--deps` points at dependency BEAMs (an ebin, or a directory of `*/ebin`
  such as `_build/dev/lib`); they are read only for behaviour callbacks.

  For a Mix project, from its root:

      faction --deps _build/dev/lib _build/dev/lib/my_app/ebin
  """

  @usage "usage: faction [--root DIR] [--out DIR] [--deps DIR]... EBIN_DIR..."

  @doc "Runs Faction with command line arguments. Returns the exit status."
  @spec run(argv :: list(String.t())) :: non_neg_integer()
  def run(argv) do
    case OptionParser.parse(argv,
           strict: [root: :string, out: :string, deps: :keep, help: :boolean]
         ) do
      {[help: true], _ebin_dirs, []} ->
        usage(:stdio, 0)

      {opts, [_ | _] = ebin_dirs, []} ->
        extract(ebin_dirs, Keyword.delete(opts, :help))

      {_opts, [], []} ->
        usage(:stderr, 1)

      {_opts, _args, invalid} ->
        IO.puts(:stderr, "faction: invalid options #{inspect(invalid)}")
        usage(:stderr, 1)
    end
  end

  @doc "Escript entry point."
  @spec main(argv :: list(String.t())) :: no_return()
  def main(argv), do: System.halt(run(argv))

  @spec extract(
          ebin_dirs :: list(String.t()),
          opts :: [root: String.t(), out: String.t(), deps: String.t()]
        ) ::
          non_neg_integer()
  defp extract(ebin_dirs, opts) do
    deps = Keyword.get_values(opts, :deps)

    case Enum.reject(ebin_dirs ++ deps, &File.dir?/1) do
      [] ->
        out = Keyword.get(opts, :out, "out")

        summary =
          Faction.run(ebin_dirs, root: Keyword.get(opts, :root, "."), out: out, deps: deps)

        report(summary, out)
        0

      missing ->
        IO.puts(:stderr, "faction: not a directory: #{Enum.join(missing, ", ")}")
        1
    end
  end

  @spec report(summary :: Faction.summary(), out :: Path.t()) :: :ok
  defp report(summary, out) do
    Enum.each(summary.skipped, fn {beam, reason} ->
      IO.puts(:stderr, "skipped #{beam}: #{reason}")
    end)

    if Enum.any?(summary.missing_behaviours) do
      IO.puts(
        :stderr,
        "no BEAM found for behaviours (pass --deps?): #{Enum.join(summary.missing_behaviours, ", ")}"
      )
    end

    counts =
      Enum.map_join(summary.rows, ", ", fn {relation, count} -> "#{relation}: #{count}" end)

    IO.puts("#{summary.beams} BEAMs → #{counts}")
    out = Path.expand(out)
    IO.puts("Load: cd #{out} && duckdb faction.duckdb < schema.sql")
    IO.puts(~s(Then: duckdb #{Path.join(out, "faction.duckdb")} "FROM faction_columns"))
  end

  @spec usage(device :: :stdio | :stderr, status :: non_neg_integer()) :: non_neg_integer()
  defp usage(device, status) do
    IO.puts(device, @usage)
    status
  end
end
