defmodule MyApp.Notifier do
  @callback deliver(message :: term()) :: :ok
  @macrocallback template(name :: atom()) :: Macro.t()

  def deliver(_message), do: :ok
end
