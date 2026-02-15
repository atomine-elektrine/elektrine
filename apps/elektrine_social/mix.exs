defmodule ElektrineSocial.MixProject do
  use Mix.Project

  def project do
    [
      app: :elektrine_social,
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
    opts = [no_warn_undefined: no_warn_undefined()]

    if Mix.env() == :test do
      Keyword.put(opts, :ignore_module_conflict, true)
    else
      opts
    end
  end

  defp no_warn_undefined do
    [
      ElektrineWeb.Endpoint,
      Elektrine.Email.Mailbox,
      Elektrine.Email.MailboxAdapter
    ]
  end

  defp deps do
    [
      {:elektrine, in_umbrella: true}
    ]
  end
end
