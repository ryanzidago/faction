defmodule Oban.Worker do
  @moduledoc "Stand-in for the Oban dependency."

  @callback perform(job :: term()) :: :ok | {:error, term()}
  @callback backoff(job :: term()) :: pos_integer()
  @callback timeout(job :: term()) :: timeout()
  @optional_callbacks backoff: 1, timeout: 1
end
