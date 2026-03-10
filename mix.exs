defmodule ElektrineUmbrella.MixProject do
  use Mix.Project

  def project do
    [
      version: "0.1.0",
      apps_path: "apps",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      releases: releases(),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: ["arbp.conformance": :test]]
  end

  defp deps, do: []

  defp releases do
    [
      elektrine: [
        applications: [
          elektrine: :permanent,
          elektrine_chat: :permanent,
          elektrine_web: :permanent,
          elektrine_email: :permanent,
          elektrine_social: :permanent,
          elektrine_vpn: :permanent,
          elektrine_password_manager: :permanent
        ]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["cmd --cd apps/elektrine mix setup"],
      seed: ["run priv/repo/seeds.exs"]
    ]
  end
end
