defmodule Faction.PhoenixTest do
  use ExUnit.Case, async: true

  alias Faction.Beam

  # Debug info holds expanded module atoms, not aliases, hence the unquotes.
  test "reads routes compiled as %Phoenix.Router.Route{} structs, as before Phoenix 1.8" do
    route =
      quote do
        %unquote(Phoenix.Router.Route){
          verb: :post,
          line: 12,
          path: "/orders/:id",
          plug: unquote(MyAppWeb.OrderController),
          plug_opts: :update,
          metadata: %{log: :debug}
        }
      end

    assert Faction.Phoenix.rows(router([route])) == %{
             routes: [
               %{
                 router: "MyAppWeb.Router",
                 verb: "POST",
                 route: "/orders/:id",
                 kind: "plug",
                 module: "MyAppWeb.OrderController",
                 action: "update"
               }
             ]
           }
  end

  test "a route keeps its row when its metadata or options are not literals" do
    route =
      quote do
        %{
          verb: :get,
          path: "/feed",
          plug: unquote(MyAppWeb.FeedController),
          plug_opts: some_call(),
          metadata: %{log: some_other_call()}
        }
      end

    assert [%{module: "MyAppWeb.FeedController", kind: "plug", action: nil}] =
             Faction.Phoenix.rows(router([route])).routes
  end

  test "modules without __routes__/0 have no routes" do
    beam = %{router([]) | definitions: []}

    assert Faction.Phoenix.rows(beam) == %{routes: []}
  end

  @spec router(routes :: list(Macro.t())) :: Beam.t()
  defp router(routes) do
    %Beam{
      module: MyAppWeb.Router,
      file: "lib/my_app_web/router.ex",
      compile_dir: ".",
      line: 1,
      definitions: [{{:__routes__, 0}, :def, [line: 1], [{[line: 1], [], [], routes}]}],
      exports: [__routes__: 0],
      behaviours: []
    }
  end
end
