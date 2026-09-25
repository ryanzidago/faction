defmodule Fallback do
  @moduledoc "Stand-in for a dependency whose @before_compile adds a catch-all clause."

  defmacro __using__(_opts) do
    quote do
      @before_compile Fallback

      def greet(name), do: "hi " <> name
      defoverridable greet: 1
    end
  end

  @doc "Defines a module whose recorded source is this file, like NimbleCSV.define/2."
  def define(name) do
    defmodule name do
      def hello, do: :world
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def handle(_message), do: :unknown
    end
  end
end
