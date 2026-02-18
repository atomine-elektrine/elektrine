defmodule ElektrineChatWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :elektrine_chat_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ElektrineChatWeb.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "== 1.8.3"},
      {:phoenix_ecto, "== 4.7.0"},
      {:phoenix_html, "== 4.3.0"},
      {:phoenix_live_view, "== 1.1.23"},
      {:jason, "== 1.4.4"},
      {:elektrine, in_umbrella: true},
      {:elektrine_chat, in_umbrella: true}
    ]
  end
end
