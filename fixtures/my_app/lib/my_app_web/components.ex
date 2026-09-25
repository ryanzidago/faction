defmodule MyAppWeb.Components do
  use Component

  attr(:label, "OK")

  def button(assigns) do
    List.wrap(assigns.label)
  end
end
