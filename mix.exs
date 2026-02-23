defmodule SchemaCache.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/BobbieBarker/schema_cache"

  def project do
    [
      app: :schema_cache,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      docs: docs(),
      name: "SchemaCache",
      source_url: @source_url,
      description:
        "An Ecto-aware caching library providing cache-aside and write-through abstractions with automatic invalidation.",
      dialyzer: [plt_add_apps: [:ecto, :ex_unit], ignore_warnings: ".dialyzer_ignore.exs"],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.lcov": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto, "~> 3.10"},
      {:ecto_sql, "~> 3.10", only: :test},
      {:postgrex, "~> 0.19", only: :test},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:redix, "~> 1.5", only: :test},
      {:elixir_cache, "~> 0.3", only: :test}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create --quiet", "ecto.migrate --migrations-path priv/test/migrations"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "guides/introduction.md",
        "guides/tutorials/installation.md",
        "guides/tutorials/basic_operations.md",
        "guides/how-to/writing_adapters.md",
        "guides/how-to/using_with_elixir_cache.md",
        "guides/explanation/architecture.md",
        "LICENSE"
      ],
      groups_for_extras: [
        "Getting Started": ["guides/introduction.md"],
        Tutorials: [~r{guides/tutorials/.?}],
        "How-to Guides": [~r{guides/how-to/.?}],
        Explanation: [~r{guides/explanation/.?}]
      ],
      groups_for_modules: [
        Core: [SchemaCache, SchemaCache.Supervisor],
        "Adapter Behaviour": [SchemaCache.Adapter],
        "Built-in Adapters": [SchemaCache.Adapters.ETS],
        Internals: [
          SchemaCache.KeyGenerator,
          SchemaCache.KeyRegistry,
          SchemaCache.SetLock
        ]
      ]
    ]
  end
end
