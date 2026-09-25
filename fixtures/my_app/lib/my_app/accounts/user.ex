defmodule MyApp.Accounts.User do
  use Ecto.Schema

  schema "users" do
    field :email, :string
    has_many :orders, MyApp.Orders.Order
    has_many :lines, through: [:orders, :lines]
    many_to_many :groups, MyApp.Accounts.Group, join_through: "users_groups"
  end
end
