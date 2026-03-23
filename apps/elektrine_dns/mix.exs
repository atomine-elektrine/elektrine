defmodule ElektrineDNS.MixProject do
  use Mix.Project

  def project do
    [
      app: :elektrine_dns,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Elektrine.DNS.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      internal_dep(:elektrine),
      internal_dep(:elektrine_web),
      {:phoenix, "== 1.8.3"},
      {:phoenix_html, "== 4.3.0"},
      {:phoenix_live_view, "== 1.1.26"},
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
