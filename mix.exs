defmodule ElektrineUmbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp deps, do: []

  defp aliases do
    [
      setup: ["cmd --cd apps/elektrine mix setup"]
    ]
  end
end
