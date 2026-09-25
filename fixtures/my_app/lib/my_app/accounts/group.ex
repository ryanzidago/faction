defmodule MyApp.Accounts.Group do
  use Ecto.Schema

  schema "groups" do
    field :name, :string
  end
end
