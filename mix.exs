defmodule SchemaCache.MixProject do
  use Mix.Project

  @version "0.1.0"
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
        "An Ecto-aware caching library implementing Read Through, Write Through, and Schema Mutation Key Eviction Strategy (SMKES).",
      dialyzer: [plt_add_apps: [:ecto, :ex_unit]],
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
      {:redix, "~> 1.5", only: :test}
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
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md"],
      groups_for_modules: [
        Core: [SchemaCache],
        "Adapter Behaviour": [SchemaCache.Adapter],
        "Built-in Adapters": [SchemaCache.Adapters.ETS],
        Internals: [SchemaCache.KeyGenerator]
      ]
    ]
  end
end
