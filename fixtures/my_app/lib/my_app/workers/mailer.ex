defmodule MyApp.Workers.Mailer do
  @behaviour Oban.Worker

  @impl Oban.Worker
  def perform(job), do: MyApp.Notifier.deliver(job)

  @impl Oban.Worker
  def backoff(_job, seconds \\ 15), do: seconds
end
