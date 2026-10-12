defmodule LiveCimgui.MixProject do
  use Mix.Project

  def project do
    [
      app: :live_cimgui,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      # `:mix` is in the PLT so the custom mix tasks in this project can be
      # analysed against the real Mix.Task callbacks and functions.
      dialyzer: [plt_add_apps: [:ex_unit, :mix]],
      aliases: aliases(),
      usage_rules: [file: "AGENTS.md", usage_rules: :all]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # `:crypto` is used for host session identifiers; `:logger` for diagnostics.
      extra_applications: [:logger, :crypto],
      # The supervision tree starts the host supervisor and the demo application
      # service; native windows are started on demand (see LiveCimgui.Application).
      mod: {LiveCimgui.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def cli do
    [
      preferred_envs: [
        ci: :test,
        test: :test,
        "live_cimgui.gui_test": :test
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:phoenix_live_view, "~> 1.0"},
      {:zigler, "~> 0.16"},
      {:vibe_kit, "~> 0.1"},
      {:igniter, "~> 0.6", only: [:dev, :test]}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end

  defp aliases() do
    [
      # The native host is built by the same Zig compiler but outside Zigler's
      # pipeline, so it is wired into `mix compile` here. It is incremental and
      # reuses Zig's own cache, so the common case is a no-op.
      compile: ["compile", "live_cimgui.build_native"],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
