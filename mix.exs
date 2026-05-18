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
    [preferred_envs: [check: :test, "arbp.conformance": :test]]
  end

  defp deps, do: []

  defp releases do
    [
      elektrine: [
        applications: [
          elektrine: :permanent,
          arblarg: :permanent,
          elektrine_dns: :permanent,
          elektrine_web: :permanent,
          elektrine_email: :permanent,
          atomine: :permanent,
          elektrine_social: :permanent,
          elektrine_vpn: :permanent,
          elektrine_nerve: :permanent,
          maid: :permanent
        ]
      ],
      elektrine_dns: [
        applications: [
          elektrine: :permanent,
          elektrine_dns: :permanent
        ]
      ]
    ]
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "deps.audit",
        "deps.unlock --check-unused",
        "test"
      ],
      setup: ["cmd --cd apps/elektrine mix setup"],
      seed: ["cmd --cd apps/elektrine mix run priv/repo/seeds.exs"]
    ]
  end
end
