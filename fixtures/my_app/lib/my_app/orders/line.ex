defmodule MyApp.Orders.Line do
  use Ecto.Schema

  @primary_key {:uuid, :binary_id, autogenerate: true}
  schema "order_lines" do
    field :quantity, :integer, source: :qty
    belongs_to :order, MyApp.Orders.Order
  end
end
