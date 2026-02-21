defmodule SchemaCache.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BobbieBarker/schema_cache"

  def project do
    [
      app: :schema_cache,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "SchemaCache",
      source_url: @source_url,
      description: "An Ecto-aware caching library implementing Read Through, Write Through, and Schema Mutation Key Eviction Strategy (SMKES).",
      dialyzer: [plt_add_apps: [:ecto]]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ecto, "~> 3.10"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
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
      main: "SchemaCache",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
