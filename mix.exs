defmodule Faction.MixProject do
  use Mix.Project

  @bylaw_ref "ed7ab4b8f02319273cdf0349f1ba65a413e474c6"

  @spec project() :: keyword()
  def project do
    [
      app: :faction,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      # Tests live next to the code they cover, e.g. lib/faction_test.exs.
      test_paths: ["lib"],
      deps: deps(),
      aliases: aliases(),
      escript: escript(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit]]
    ]
  end

  @spec cli() :: keyword()
  def cli do
    [preferred_envs: [precommit: :test, dialyzer: :test]]
  end

  @spec application() :: keyword()
  def application do
    # Embedded in the escript so behaviours from Elixir's own applications
    # (Mix.Task, EEx.Engine, ...) resolve for the callbacks pass.
    [extra_applications: [:logger, :mix, :eex, :ex_unit]]
  end

  # Debug info and source parsing create atoms (~20 per BEAM on Plausible), so
  # the escript raises the VM's atom limit for large projects.
  @spec escript() :: keyword()
  defp escript do
    [main_module: Faction.CLI, emu_args: "+t 16777216"]
  end

  @spec deps() :: list(tuple())
  defp deps do
    [
      {:bylaw_credo,
       github: "ryanzidago/bylaw",
       ref: @bylaw_ref,
       sparse: "packages/bylaw_credo",
       only: [:dev, :test],
       runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Only for compiling the test fixture's Ecto schemas; Faction never loads Ecto.
      {:ecto, "~> 3.12", only: :test}
    ]
  end

  @spec aliases() :: keyword()
  defp aliases do
    [
      # deps.get runs in its own VM first: deps.unlock --unused drops lock entries whose
      # parent isn't fetched yet.
      precommit: [
        "cmd mix deps.get",
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "dialyzer",
        "test --warnings-as-errors"
      ]
    ]
  end
end
