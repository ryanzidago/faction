defmodule MyApp.Options do
  defmacro __using__(opts \\ []) do
    quote do
      @options unquote(opts)
    end
  end
end
