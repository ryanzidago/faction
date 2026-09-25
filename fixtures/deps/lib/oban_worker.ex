defmodule Oban.Worker do
  @moduledoc "Stand-in for the Oban dependency."

  @callback perform(job :: term()) :: :ok | {:error, term()}
  @callback timeout(job :: term()) :: timeout()
  @optional_callbacks timeout: 1
end
