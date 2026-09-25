# Checks that every external callee is a function its module exports.
# Export the view, then run with the app's dependency ebins on the code path:
#
#   duckdb faction.duckdb "COPY (SELECT * FROM external_functions) TO 'ext.jsonl'"
#   elixir -pa _build/dev/lib/*/ebin validation/check_external.exs out/ext.jsonl
[file] = System.argv()

results =
  file
  |> File.stream!()
  |> Enum.map(&JSON.decode!/1)
  |> Enum.group_by(fn %{"module" => name, "function" => function, "arity" => arity} ->
    module = if name =~ ~r/^[A-Z]/, do: Module.concat([name]), else: String.to_atom(name)
    function = String.to_atom(function)

    cond do
      not Code.ensure_loaded?(module) -> :module_not_found
      function_exported?(module, function, arity) -> :exported
      true -> :not_exported
    end
  end)

for {status, rows} <- Enum.sort(results), do: IO.puts("#{status}: #{length(rows)}")

for status <- [:not_exported, :module_not_found], row <- Enum.take(Map.get(results, status, []), 20) do
  IO.puts("  #{status} #{row["module"]}.#{row["function"]}/#{row["arity"]}")
end
