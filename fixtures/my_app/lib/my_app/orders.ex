defmodule MyApp.Orders do
  def list_orders(user_id) do
    user_id |> query() |> MyApp.Repo.all()
  end

  defp query(user_id), do: {MyApp.Orders.Order, user_id}
end
