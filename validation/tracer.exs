# Records every function call the Elixir compiler resolves, as an independent
# check of function_calls. Preload it into a Mix compile of the target app:
#
#   TRACE_OUT=/abs/trace.jsonl elixir -r validation/tracer.exs -S mix compile --force
#
# Then load the trace and run compare_calls.sql (see README.md).
defmodule Faction.Validation.Tracer do
  @spec trace(tuple(), Macro.Env.t()) :: :ok
  def trace({kind, meta, module, name, arity}, env)
      when kind in [:remote_function, :imported_function] and not is_nil(env.function),
      do: record(env, module, name, arity, meta)

  def trace({:local_function, meta, name, arity}, env) when not is_nil(env.function),
    do: record(env, env.module, name, arity, meta)

  def trace(_event, _env), do: :ok

  @spec record(Macro.Env.t(), module(), atom(), arity(), keyword()) :: :ok
  defp record(env, module, name, arity, meta) do
    {function, function_arity} = env.function

    row = %{
      caller_module: name(env.module),
      caller_function: Atom.to_string(function),
      caller_arity: function_arity,
      callee_module: name(module),
      callee_function: Atom.to_string(name),
      callee_arity: arity,
      line: meta[:line]
    }

    :ets.insert(:faction_validation_trace, {make_ref(), row})
    :ok
  end

  @spec name(module()) :: String.t()
  defp name(module), do: String.replace_prefix(Atom.to_string(module), "Elixir.", "")
end

table = :ets.new(:faction_validation_trace, [:public, :named_table, :bag])
:ets.give_away(table, Process.whereis(:init), [])
Code.put_compiler_option(:tracers, [Faction.Validation.Tracer])

System.at_exit(fn _status ->
  rows = for {_ref, row} <- :ets.tab2list(:faction_validation_trace), do: [JSON.encode!(row), ?\n]
  File.write!(System.fetch_env!("TRACE_OUT"), rows)
end)
