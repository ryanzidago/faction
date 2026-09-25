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

  @doc "Directory holding the stand-in dependencies' compiled BEAMs."
  @spec deps_ebin() :: Path.t()
  def deps_ebin, do: Path.join(build_dir(), "deps/ebin")

  @doc "Directory holding the hand-written expected output."
  @spec expected_dir() :: Path.t()
  def expected_dir, do: Path.expand("expected", __DIR__)

  @doc "Compiles the dependencies, then the app, failing on any warning."
  @spec compile!() :: :ok
  def compile! do
    unload_compiled()
    File.rm_rf!(build_dir())
    compile!(Path.expand("deps/lib", __DIR__), deps_ebin())
    compile!(Path.join(root(), "lib"), app_ebin())
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
