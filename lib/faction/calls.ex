defmodule Faction.Calls do
  @moduledoc """
  Call sites in the expanded Elixir AST of one module's definitions.

  The AST in the debug info is already expanded: aliases and imports are
  resolved to remote calls, macros are expanded, and pipes are gone. Local
  calls are calls to a name and arity the module defines.
  """

  alias Faction.Beam

  @typedoc "Where a call appears: {path, line}. Both are nil when the location is not reported."
  @type location() :: {String.t() | nil, pos_integer() | nil}

  @typedoc "Maps the metadata of a definition and of a call in it to the call's location."
  @type locate() :: (keyword(), keyword() -> location())

  @doc """
  Returns `{function_calls, dynamic_function_calls}` rows for a module, in
  definition order (sorted by compiled name and arity), then source order.
  """
  @spec rows(beam :: Beam.t(), locate :: locate()) :: {list(map()), list(map())}
  def rows(beam, locate) do
    module = Beam.module_name(beam.module)

    locals =
      MapSet.new(beam.definitions, fn {name_arity, _kind, _meta, _clauses} -> name_arity end)

    {calls, dynamic_calls} =
      beam.definitions
      |> Enum.map(fn {{name, arity}, kind, meta, clauses} ->
        {Beam.compiled_name(kind, name, arity), meta, clauses}
      end)
      |> Enum.sort_by(fn {name_arity, _meta, _clauses} -> name_arity end)
      |> Enum.reduce({[], []}, fn {{function, arity}, meta, clauses}, acc ->
        caller = %{caller_module: module, caller_function: function, caller_arity: arity}

        context = %{
          module: beam.module,
          locals: locals,
          caller: caller,
          locate: &locate.(meta, &1)
        }

        # Clauses are {meta, args, guards, body}; only their parts are AST.
        clauses
        |> Enum.map(fn {_meta, args, guards, body} -> [args, guards, body] end)
        |> walk(context, acc)
      end)

    {Enum.reverse(calls), Enum.reverse(dynamic_calls)}
  end

  @spec walk(ast :: term(), context :: map(), acc :: {list(map()), list(map())}) ::
          {list(map()), list(map())}
  defp walk(ast, context, acc) do
    {_ast, acc} = Macro.prewalk(ast, acc, &visit(&1, &2, context))
    acc
  end

  # Macro.prewalk visits the children of the node a visit returns, not the
  # node itself: returning nil stops the walk, and a node that still needs a
  # visit is returned inside a list.
  @spec visit(node :: term(), acc :: {list(map()), list(map())}, context :: map()) ::
          {term(), {list(map()), list(map())}}
  defp visit({:&, meta, [{:/, _slash_meta, [target, arity]}]}, acc, context)
       when is_integer(arity) do
    case target do
      {{:., _dot_meta, [module, function]}, _call_meta, []}
      when is_atom(module) and is_atom(function) ->
        {nil, add_call(acc, context, module, function, arity, "capture", meta)}

      {{:., _dot_meta, [receiver, function]}, _call_meta, []} when is_atom(function) ->
        {[receiver], add_dynamic_call(acc, context, function, arity, meta)}

      {function, _local_meta, context_atom} when is_atom(function) and is_atom(context_atom) ->
        {nil, add_call(acc, context, context.module, function, arity, "capture", meta)}

      _other ->
        {[target], acc}
    end
  end

  # super(args) calls the overridden definition, renamed by defoverridable.
  # The dispatch clause of a default argument is also a super call; for a
  # macro its target is the compiled MACRO- name and arity.
  defp visit({:super, meta, args}, acc, context) when is_list(args) do
    case meta[:super] do
      {kind, name} when is_atom(name) ->
        {function, arity} = Beam.compiled_name(kind, name, Enum.count(args))
        {args, add_call(acc, context, context.module, function, arity, "call", meta)}

      _unknown ->
        {args, acc}
    end
  end

  # apply/3 with a literal module, function and argument list is a direct
  # call (the Erlang compiler emits it as one); otherwise it is dynamic.
  defp visit(
         {{:., _dot_meta, [:erlang, :apply]}, meta, [module, function, args] = parts},
         acc,
         context
       ) do
    case {module, function, list_length(args)} do
      {module, function, arity}
      when is_atom(module) and is_atom(function) and is_integer(arity) ->
        {args, add_call(acc, context, module, function, arity, "call", meta)}

      {_module, function, arity} when is_atom(function) ->
        {parts, add_dynamic_call(acc, context, function, arity, meta)}

      {_module, _function, arity} ->
        {parts, add_dynamic_call(acc, context, nil, arity, meta)}
    end
  end

  # `and` and `or` expand to Erlang's andalso/orelse, which are control flow,
  # not functions.
  defp visit({{:., _dot_meta, [:erlang, operator]}, _meta, args}, acc, _context)
       when operator in [:andalso, :orelse] and is_list(args) do
    {args, acc}
  end

  defp visit({{:., _dot_meta, [module, function]}, meta, args}, acc, context)
       when is_atom(module) and is_atom(function) and is_list(args) do
    {args, add_call(acc, context, module, function, Enum.count(args), "call", meta)}
  end

  defp visit({{:., _dot_meta, [receiver, function]}, meta, args}, acc, context)
       when is_atom(function) and is_list(args) do
    if meta[:no_parens] == true and Enum.empty?(args) do
      # Map field access such as conn.assigns, not a call. The receiver can
      # itself be a call (Repo.get!(id).name), so it is walked, not skipped.
      {[receiver], acc}
    else
      {[receiver | args], add_dynamic_call(acc, context, function, Enum.count(args), meta)}
    end
  end

  defp visit({function, meta, args} = node, acc, context)
       when is_atom(function) and is_list(args) do
    if MapSet.member?(context.locals, {function, Enum.count(args)}) do
      {args, add_call(acc, context, context.module, function, Enum.count(args), "call", meta)}
    else
      {node, acc}
    end
  end

  defp visit(node, acc, _context), do: {node, acc}

  @spec add_call(
          acc :: {list(map()), list(map())},
          context :: map(),
          module :: module(),
          function :: atom() | String.t(),
          arity :: arity(),
          kind :: String.t(),
          meta :: keyword()
        ) :: {list(map()), list(map())}
  defp add_call({calls, dynamic_calls}, context, module, function, arity, kind, meta) do
    {path, line} = context.locate.(meta)

    row =
      Map.merge(context.caller, %{
        callee_module: Beam.module_name(module),
        callee_function: to_string(function),
        callee_arity: arity,
        kind: kind,
        path: path,
        line: line
      })

    {[row | calls], dynamic_calls}
  end

  @spec add_dynamic_call(
          acc :: {list(map()), list(map())},
          context :: map(),
          function :: atom() | nil,
          arity :: arity() | nil,
          meta :: keyword()
        ) :: {list(map()), list(map())}
  defp add_dynamic_call({calls, dynamic_calls}, context, function, arity, meta) do
    {path, line} = context.locate.(meta)

    row =
      Map.merge(context.caller, %{
        callee_function: function && Atom.to_string(function),
        callee_arity: arity,
        path: path,
        line: line
      })

    {calls, [row | dynamic_calls]}
  end

  @spec list_length(ast :: term()) :: non_neg_integer() | nil
  defp list_length(list) when is_list(list) do
    if List.improper?(list) do
      nil
    else
      Enum.count(list)
    end
  end

  defp list_length(_ast), do: nil
end
