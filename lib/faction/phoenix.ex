defmodule Faction.Phoenix do
  @moduledoc """
  Phoenix routes, read from the literal list returned by a router's
  `__routes__/0` in its debug info.

  Phoenix 1.8 compiles each route to a map of verb, path, plug, plug_opts,
  helper and metadata; older versions compile the whole
  `%Phoenix.Router.Route{}` struct. Both are read field by field, because a
  route's metadata can hold non-literal terms (e.g. a LiveView's `on_mount`
  captures) that would make the whole route undecodable.
  """

  alias Faction.Beam
  alias Faction.Literal

  @typedoc "Rows keyed by relation name."
  @type rows() :: %{routes: list(map())}

  @doc "The route rows of a module; empty unless it is a Phoenix router."
  @spec rows(beam :: Beam.t()) :: rows()
  def rows(beam) do
    router = Beam.module_name(beam.module)

    routes =
      for {{:__routes__, 0}, :def, _meta, [{_clause_meta, [], [], routes}]} <- beam.definitions,
          is_list(routes),
          route <- routes,
          row = route_row(router, route),
          do: row

    %{routes: routes}
  end

  @spec route_row(router :: String.t(), route :: Macro.t()) :: map() | nil
  defp route_row(router, {:%, _meta, [_struct, {:%{}, _map_meta, pairs}]}),
    do: route_row(router, {:%{}, [], pairs})

  defp route_row(router, {:%{}, _meta, pairs}) when is_list(pairs) do
    with {:ok, verb} when is_atom(verb) <- field(pairs, :verb),
         {:ok, path} when is_binary(path) <- field(pairs, :path),
         {:ok, plug} when is_atom(plug) <- field(pairs, :plug) do
      {kind, module, action} = target(plug, field(pairs, :plug_opts), metadata(pairs))

      %{
        router: router,
        verb: String.upcase(Atom.to_string(verb)),
        route: path,
        kind: kind,
        module: Beam.module_name(module),
        action: action && Atom.to_string(action)
      }
    else
      _not_a_route -> nil
    end
  end

  defp route_row(_router, _route), do: nil

  # What the route dispatches to: a LiveView and its live action, a forwarded
  # plug, or a plug (a controller) with its action.
  @spec target(
          plug :: module(),
          plug_opts :: {:ok, term()} | :error,
          metadata :: list({term(), Macro.t()})
        ) :: {String.t(), module(), atom() | nil}
  defp target(plug, plug_opts, metadata) do
    live_view =
      case List.keyfind(metadata, :phoenix_live_view, 0) do
        {:phoenix_live_view, {:{}, _meta, [module, action | _rest]}} when is_atom(module) ->
          {module, action}

        _not_live ->
          nil
      end

    cond do
      live_view ->
        {module, action} = live_view
        {"live", module, atom(action)}

      List.keymember?(metadata, :forward, 0) ->
        {"forward", plug, nil}

      true ->
        case plug_opts do
          {:ok, action} -> {"plug", plug, atom(action)}
          :error -> {"plug", plug, nil}
        end
    end
  end

  @spec field(pairs :: list(Macro.t()), key :: atom()) :: {:ok, term()} | :error
  defp field(pairs, key) do
    case List.keyfind(pairs, key, 0) do
      {^key, ast} -> Literal.literal(ast)
      nil -> :error
    end
  end

  # The metadata map's pairs, left as AST so each can be read on its own.
  @spec metadata(pairs :: list(Macro.t())) :: list({term(), Macro.t()})
  defp metadata(pairs) do
    case List.keyfind(pairs, :metadata, 0) do
      {:metadata, {:%{}, _meta, metadata}} when is_list(metadata) -> metadata
      _none -> []
    end
  end

  # An action is an atom other than nil or a boolean.
  @spec atom(value :: term()) :: atom() | nil
  defp atom(value) when is_atom(value) and value not in [nil, true, false], do: value
  defp atom(_value), do: nil
end
