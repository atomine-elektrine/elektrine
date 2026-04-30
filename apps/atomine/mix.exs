defmodule Atomine.MixProject do
  use Mix.Project

  def project do
    [
      app: :atomine,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      internal_dep(:elektrine)
    ]
  end

  defp internal_dep(app) do
    if Mix.Project.umbrella?() do
      {app, in_umbrella: true}
    else
      {app, path: "../#{app}"}
    end
  end
end
