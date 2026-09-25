defmodule MyApp.OrdersTest do
  use ExUnit.Case, async: true

  describe "list_orders/1" do
    test "returns no orders for a new user" do
      assert MyApp.Orders.list_orders(1) == []
    end
  end
end
