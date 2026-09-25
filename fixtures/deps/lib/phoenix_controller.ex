defmodule Phoenix.Controller do
  @moduledoc "Stand-in for the Phoenix dependency."

  def render(conn, _template, _assigns), do: conn
end
