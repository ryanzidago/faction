defmodule MyAppWeb.Router do
  use Phoenix.Router

  get("/orders", MyAppWeb.OrderController, :index)
  live("/dashboard", MyAppWeb.DashboardLive, :index)
  forward("/admin", MyAppWeb.AdminPlug)
end
