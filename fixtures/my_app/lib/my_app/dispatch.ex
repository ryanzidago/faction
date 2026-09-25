defmodule MyApp.Dispatch do
  def run(mod, args), do: apply(mod, :handle, args)

  def run_known(user_id), do: apply(MyApp.Orders, :list_orders, [user_id])

  def via_variable(mod, value), do: mod.handle(value)

  def captures do
    [&MyApp.Orders.list_orders/1, &local/1, &String.upcase/1, &(&1 + 1)]
  end

  def invoke(fun, value), do: fun.(value)

  defp local(value) when is_integer(value), do: value + 1

  def run_handler(args), do: run(MyApp.Handler, args)

  def order?(%MyApp.Orders.Order{}), do: true
  def order?(_other), do: false
end
