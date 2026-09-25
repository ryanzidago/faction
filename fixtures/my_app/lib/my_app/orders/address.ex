defmodule MyApp.Orders.Address do
  use Ecto.Schema

  embedded_schema do
    field :city, :string
  end
end
