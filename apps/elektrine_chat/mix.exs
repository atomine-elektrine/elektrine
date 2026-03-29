defmodule ElektrineChat.MixProject do
  use Mix.Project

  def project do
    [
      app: :elektrine_chat,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: elixirc_options(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ElektrineChat.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp elixirc_options do
    if Mix.env() == :test do
      [ignore_module_conflict: true]
    else
      []
    end
  end

  defp deps do
    [
      internal_dep(:elektrine),
      internal_dep(:elektrine_web),
      {:phoenix, "== 1.8.5"},
      {:phoenix_html, "== 4.3.0"},
      {:phoenix_live_view, "== 1.1.28"},
      {:jason, "== 1.4.4"}
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
