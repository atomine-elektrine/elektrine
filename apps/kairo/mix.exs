defmodule Kairo.MixProject do
  use Mix.Project

  def project do
    [
      app: :kairo,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      internal_dep(:elektrine)
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end

  defp internal_dep(app, opts \\ []) do
    dep_opts =
      if Mix.Project.umbrella?() do
        [in_umbrella: true]
      else
        [path: "../#{app}"]
      end

    {app, Keyword.merge(dep_opts, opts)}
  end
end
