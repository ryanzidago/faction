defmodule MyApp.Workers.Mailer do
  @behaviour Oban.Worker

  @impl Oban.Worker
  def perform(job), do: MyApp.Notifier.deliver(job)
end
