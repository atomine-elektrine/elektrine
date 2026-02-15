defmodule ElektrinePasswordManager.MixProject do
  use Mix.Project

  def project do
    [
      app: :elektrine_password_manager,
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
      extra_applications: [:logger]
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
      {:elektrine, in_umbrella: true}
    ]
  end
end
