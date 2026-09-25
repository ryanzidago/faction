defmodule MyApp.Orders.Order do
  use Ecto.Schema

  schema "orders" do
    field :total, :decimal
    field :status, Ecto.Enum, values: [:pending, :paid]
    field :tags, {:array, :string}, default: []
    belongs_to :user, MyApp.Accounts.User
    has_many :lines, MyApp.Orders.Line
    embeds_one :address, MyApp.Orders.Address
    timestamps()
  end
end
