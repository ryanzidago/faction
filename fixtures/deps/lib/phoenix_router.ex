defmodule Phoenix.Router do
  @moduledoc """
  Stand-in for the Phoenix dependency's router: `__routes__/0` returns one
  map per route, shaped like Phoenix 1.8's. A live route's metadata holds a
  capture, as `on_mount` hooks do, so the route is not a literal as a whole.
  """

  defmacro __using__(_opts) do
    quote do
      import Phoenix.Router, only: [get: 3, live: 3, forward: 2]
      Module.register_attribute(__MODULE__, :phoenix_routes, accumulate: true)
      @before_compile Phoenix.Router
    end
  end

  defmacro get(path, controller, action) do
    controller = Macro.expand(controller, __CALLER__)
    route(:get, path, controller, action, quote(do: %{log: :debug}))
  end

  defmacro live(path, live_view, action) do
    live_view = Macro.expand(live_view, __CALLER__)

    metadata =
      quote do
        %{
          log: :debug,
          phoenix_live_view:
            {unquote(live_view), unquote(action), [action: unquote(action)],
             %{extra: %{on_mount: [&MyAppWeb.Components.button/1]}}}
        }
      end

    route(:get, path, Phoenix.LiveView.Plug, action, metadata)
  end

  defmacro forward(path, plug) do
    plug = Macro.expand(plug, __CALLER__)
    segments = [String.trim_leading(path, "/")]
    route(:*, path, plug, [], quote(do: %{forward: unquote(segments), log: :debug}))
  end

  # The route as the map expression __routes__/0 returns, stored unevaluated.
  @spec route(
          verb :: atom(),
          path :: String.t(),
          plug :: module(),
          plug_opts :: term(),
          metadata :: Macro.t()
        ) :: Macro.t()
  defp route(verb, path, plug, plug_opts, metadata) do
    route =
      quote do
        %{
          verb: unquote(verb),
          path: unquote(path),
          plug: unquote(plug),
          plug_opts: unquote(plug_opts),
          helper: nil,
          metadata: unquote(metadata)
        }
      end

    quote do
      @phoenix_routes unquote(Macro.escape(route))
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:phoenix_routes) |> Enum.reverse()

    quote do
      def __routes__, do: unquote(routes)
    end
  end
end
