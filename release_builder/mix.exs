Code.require_file("module_selection.exs", __DIR__)

defmodule ElektrineReleaseBuilder.MixProject do
  use Mix.Project

  def project do
    [
      app: :elektrine_release_builder,
      version: "0.1.0",
      build_path: build_path(),
      config_path: "config/config.exs",
      deps_path: "../deps",
      lockfile: "../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    ElektrineReleaseBuilder.ModuleSelection.selected_apps()
    |> Kernel.++([:elektrine_dns])
    |> Enum.uniq()
    |> Enum.map(&internal_dep/1)
  end

  defp build_path do
    "../_build/release_builder/#{ElektrineReleaseBuilder.ModuleSelection.build_slug()}"
  end

  defp releases do
    [
      elektrine: [
        applications: release_applications()
      ]
    ]
  end

  defp release_applications do
    ElektrineReleaseBuilder.ModuleSelection.selected_apps()
    |> Kernel.++([:elektrine_dns])
    |> Enum.uniq()
    |> Enum.map(&{&1, :permanent})
    |> Kernel.++(elektrine_release_builder: :load)
  end

  defp internal_dep(app) do
    {app, path: "../apps/#{app}"}
  end
end
