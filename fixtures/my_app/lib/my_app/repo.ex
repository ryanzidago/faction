defmodule MyApp.Repo do
  def all(_query), do: []

  def get!(_query), do: %{total: 0}
end
