# Runs inside the app synthetic_app.exs generates (`mix run --no-start`): the
# phx.gen.* tasks listed in a JSON plan file, in order, in one process, which
# is about 50× faster than one `mix` per resource. Every task passes
# --merge-with-existing-context, so no prompt is expected; one that appears
# fails the run.
defmodule Synth.Scaffold do
  @spec main([String.t()]) :: :ok
  def main([plan]) do
    Mix.shell(Mix.Shell.Process)
    tasks = plan |> File.read!() |> JSON.decode!()

    tasks
    |> Enum.with_index(1)
    |> Enum.each(fn {[task, args], i} ->
      Mix.Task.rerun(task, args)
      flush()
      if rem(i, 500) == 0, do: IO.puts(:stderr, "generated #{i}/#{length(tasks)} resources")
    end)
  end

  # Drops what the generators printed.
  @spec flush() :: :ok
  defp flush do
    receive do
      {:mix_shell, _, _} -> flush()
    after
      0 -> :ok
    end
  end
end

Synth.Scaffold.main(System.argv())
