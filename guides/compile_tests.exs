# Compiles a project's ExUnit test files to BEAM files, so Faction can index
# them like any other ebin directory. Faction never compiles the target
# project; the project runs this script itself, from its root:
#
#     MIX_ENV=test mix run --no-start path/to/compile_tests.exs
#     faction --deps _build/test/lib _build/test/lib/my_app/ebin _build/test/test_beams
#
# Environment:
#
#   * `OUT` - where to write the test BEAMs (default `_build/test/test_beams`,
#     emptied first)
#   * `PATTERN` - which test files to compile (default `test/**/*_test.exs`)
#
# The app itself is not started. Its dependencies are, because a test module
# body may call them while compiling (`for tz <- Tzdata.zone_list() do test ...`).
# A test file whose module body needs the running app (`@host Endpoint.host()`)
# cannot compile; it is skipped and reported, and the rest is compiled.

out = System.get_env("OUT", "_build/test/test_beams")
pattern = System.get_env("PATTERN", "test/**/*_test.exs")

# Under plain `elixir` (no Mix project) there are no dependencies to start.
if Process.whereis(Mix.ProjectStack) && Mix.Project.get() do
  app = Mix.Project.config()[:app]
  Application.load(app)

  for dependency <- Application.spec(app, :applications) do
    {:ok, _started} = Application.ensure_all_started(dependency)
  end
end

# `use ExUnit.Case` registers each test module with the ExUnit server while it
# compiles; `autorun: false` keeps the tests from running.
ExUnit.start(autorun: false)
Code.compiler_options(debug_info: true)

compile = fn compile, files, skipped ->
  File.rm_rf!(out)
  File.mkdir_p!(out)

  case Kernel.ParallelCompiler.compile_to_path(files, out, return_diagnostics: true) do
    {:ok, modules, _warnings} ->
      {modules, skipped}

    {:error, errors, _warnings} ->
      failed = errors |> Enum.map(& &1.file) |> Enum.uniq()

      # An error no test file is to blame for would otherwise retry forever.
      if files -- failed == files, do: raise("test compilation failed: #{inspect(errors)}")

      compile.(compile, files -- failed, skipped ++ failed)
  end
end

files = pattern |> Path.wildcard() |> Enum.map(&Path.expand/1)
{modules, skipped} = compile.(compile, files, [])

for file <- skipped, do: IO.puts("skipped #{Path.relative_to_cwd(file)}")
IO.puts("wrote #{length(modules)} test modules to #{out}")
