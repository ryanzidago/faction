defmodule MyAppWeb.OrderController do
  use MyAppWeb, :controller
  def index(conn, _params) do
    orders = MyApp.Orders.list_orders(conn.assigns.user_id)
    render(conn, :index, orders: orders)
  end
end
