defmodule MyApp.Cache do
  use GenServer

  @impl GenServer
  def init(state), do: {:ok, state}
end
