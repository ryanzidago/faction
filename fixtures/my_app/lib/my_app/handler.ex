defmodule MyApp.Handler do
  use Fallback

  def handle(:ping), do: :pong

  def handle(:pong),
    do: :ping

  def greet(name), do: super(name) <> "!"

  def first_total(order_id), do: MyApp.Repo.get!(order_id).total
end
