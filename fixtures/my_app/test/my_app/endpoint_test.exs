defmodule MyApp.EndpointTest do
  use ExUnit.Case, async: true

  # Reads configuration only the running app has, while compiling, so
  # `guides/compile_tests.exs` skips this file.
  @host Application.fetch_env!(:my_app, :host)

  test "knows its host" do
    assert @host
  end
end
