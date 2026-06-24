defmodule ShhAi.MixProject do
  use Mix.Project

  def project do
    [
      app: :shh_ai,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.github": :test,
        "coveralls.html": :test,
        "test.performance": :test,
        "test.stress": :test
      ],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ShhAi.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.github": :test,
        "coveralls.html": :test,
        "test.performance": :test,
        "test.stress": :test,
        precommit: :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test),
    do: ["lib", "test/support", "test/performance", "test/performance/fixtures"]

  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.5"},
      {:ecto, "~> 3.13"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.23"},
      {:cloak, "~> 1.1"},
      {:cloak_ecto, "~> 1.3"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:apexcharts,
       github: "apexcharts/apexcharts.js",
       tag: "v5.10.6",
       app: false,
       sparse: "dist",
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:finch, "~> 0.19"},
      {:redix, "~> 1.5.3"},
      {:bumblebee, "~> 0.6"},
      {:nx, "~> 0.10"},
      {:exla, "~> 0.10"},
      {:credo, "~> 1.7.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21.0", only: [:dev, :test], runtime: false},
      {:git_hooks, "~> 0.7.0", only: [:test, :dev], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:benchee, "~> 1.3", only: :test},
      {:benchee_html, "~> 1.0", only: :test},
      {:meck, "~> 0.9", only: :test},
      {:uuid, "~> 1.1"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      # The proxy is stateless - no database needed for tests
      test: ["test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind shh_ai", "esbuild shh_ai"],
      "assets.deploy": [
        "tailwind shh_ai --minify",
        "esbuild shh_ai --minify",
        "phx.digest"
      ],
      "test.performance": ["test --only performance --color"],
      "test.stress": ["test --only stress --color"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
