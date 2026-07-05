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
          kairo: :permanent,
          atomine: :permanent,
          elektrine_social: :permanent,
          elektrine_vpn: :permanent,
          elektrine_nerve: :permanent,
          elektrine_uptime: :permanent,
          paige: :permanent
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
        "do --app elektrine cmd --cd ../.. scripts/check_tracked_generated_artifacts.sh",
        "do --app elektrine cmd --cd ../.. scripts/check_maintainability_budgets.sh",
        "do --app elektrine cmd --cd ../.. scripts/check_legacy_marker_budget.sh",
        "do --app elektrine cmd --cd assets npm run check",
        "compile --warnings-as-errors",
        "credo --strict",
        "deps.audit",
        "hex.audit",
        "deps.unlock --check-unused",
        "test"
      ],
      setup: ["cmd --cd apps/elektrine mix setup"],
      seed: ["cmd --cd apps/elektrine mix run priv/repo/seeds.exs"]
    ]
  end
end
