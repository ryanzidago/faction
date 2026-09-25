defmodule Faction.Fixture do
  @moduledoc """
  The rung-1 fixture: a tiny app under `fixtures/my_app` whose stand-in
  dependencies live in `fixtures/deps`. Tests compile it once; Faction itself
  never compiles anything. Shared by the tests and `guides/tour.exs`.
  """

  @doc "Repository root of the fixture app."
  @spec root() :: Path.t()
  def root, do: Path.expand("my_app", __DIR__)

  @doc "Directory holding the fixture app's compiled BEAMs."
  @spec app_ebin() :: Path.t()
  def app_ebin, do: Path.join(build_dir(), "my_app/ebin")

  @doc "Directory holding the fixture app's compiled test BEAMs."
  @spec test_ebin() :: Path.t()
  def test_ebin, do: Path.join(build_dir(), "my_app_test/ebin")

  @doc "Directory holding the stand-in dependencies' compiled BEAMs."
  @spec deps_ebin() :: Path.t()
  def deps_ebin, do: Path.join(build_dir(), "deps/ebin")

  @doc "Directory holding the hand-written expected output."
  @spec expected_dir() :: Path.t()
  def expected_dir, do: Path.expand("expected", __DIR__)

  @doc """
  Compiles the dependencies, then the app, failing on any warning, then the
  app's tests with `guides/compile_tests.exs`.
  """
  @spec compile!() :: :ok
  def compile! do
    unload_compiled()
    File.rm_rf!(build_dir())
    compile!(Path.expand("deps/lib", __DIR__), deps_ebin())
    compile!(Path.join(root(), "lib"), app_ebin())
    compile_tests!()
  end

  @spec compile!(source_dir :: Path.t(), ebin :: Path.t()) :: :ok
  defp compile!(source_dir, ebin) do
    files = Path.wildcard(Path.join(source_dir, "**/*.ex"))
    File.mkdir_p!(ebin)

    case Kernel.ParallelCompiler.compile_to_path(files, ebin, return_diagnostics: true) do
      {:ok, _modules, %{compile_warnings: [], runtime_warnings: []}} -> :ok
      other -> raise "fixture #{source_dir} did not compile cleanly: #{inspect(other)}"
    end
  end

  # In a separate VM: `use ExUnit.Case` registers each compiled test module
  # with the ExUnit server, and this VM's ExUnit would then run it.
  @spec compile_tests!() :: :ok
  defp compile_tests! do
    script = Path.expand("../guides/compile_tests.exs", __DIR__)

    {output, status} =
      System.cmd("elixir", ["-pa", app_ebin(), "-pa", deps_ebin(), script],
        cd: root(),
        env: [{"OUT", test_ebin()}],
        stderr_to_stdout: true
      )

    expected = ["skipped test/my_app/endpoint_test.exs", "wrote 3 test modules to #{test_ebin()}"]

    if status != 0 or not Enum.all?(expected, &String.contains?(output, &1)) do
      raise "fixture tests did not compile as expected:\n#{output}"
    end

    :ok
  end

  # Recompiling in a VM that already loaded the fixture (a re-evaluated
  # Livebook cell) would warn about redefined modules; unload them first.
  @spec unload_compiled() :: :ok
  defp unload_compiled do
    for beam <- Path.wildcard(Path.join(build_dir(), "*/ebin/*.beam")) do
      module = beam |> Path.basename(".beam") |> String.to_atom()
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end

    :ok
  end

  @spec build_dir() :: Path.t()
  defp build_dir, do: Path.join(Mix.Project.build_path(), "fixture")
end
