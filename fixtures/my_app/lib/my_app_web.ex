defmodule MyAppWeb do
  def controller do
    quote location: :keep do
      import Phoenix.Controller

      def controller?, do: MyApp.Repo.all(:controllers) != []
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
