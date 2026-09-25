defmodule Component do
  @moduledoc """
  Stand-in for Phoenix.Component: a function component declared with `attr`
  is renamed by defoverridable, and a generated wrapper at the def line
  merges the attribute defaults and calls super.
  """

  defmacro __using__(_opts) do
    quote do
      import Component, only: [attr: 2]
      Module.register_attribute(__MODULE__, :__components__, accumulate: true)
      @on_definition Component
      @before_compile Component
    end
  end

  defmacro attr(name, default) do
    quote do
      Module.put_attribute(
        __MODULE__,
        :__attrs__,
        Map.put(Module.get_attribute(__MODULE__, :__attrs__) || %{}, unquote(name), unquote(default))
      )
    end
  end

  def __on_definition__(env, :def, name, [_assigns], _guards, _body) do
    if attrs = Module.delete_attribute(env.module, :__attrs__) do
      Module.put_attribute(env.module, :__components__, {name, env.line, attrs})
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  defmacro __before_compile__(env) do
    components = Module.get_attribute(env.module, :__components__)

    defs =
      for {name, line, attrs} <- components do
        body =
          quote do
            merged = Map.merge(unquote(Macro.escape(attrs)), assigns)
            super(merged)
          end

        # Like Phoenix, drop the context so the wrapper still warns as user code.
        {remote, meta, [{call_name, call_meta, call_args}, args]} =
          quote line: line do
            Kernel.def unquote(name)(assigns) do
              unquote(body)
            end
          end

        {remote, meta, [{call_name, Keyword.delete(call_meta, :context), call_args}, args]}
      end

    quote do
      defoverridable unquote(for {name, _line, _attrs} <- components, do: {name, 1})
      unquote_splicing(defs)
    end
  end
end
