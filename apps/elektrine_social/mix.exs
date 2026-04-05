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
      ElektrineWeb,
      ElektrineWeb.Endpoint,
      ElektrineWeb.Gettext,
      ElektrineWeb.Layouts,
      ElektrineWeb.Router,
      ElektrineWeb.API.Response,
      ElektrineWeb.ClientIP,
      ElektrineWeb.Components.Platform.ZNav,
      ElektrineWeb.Components.Social.ReplyItem,
      ElektrineWeb.CoreComponents,
      ElektrineWeb.FallbackController,
      ElektrineWeb.HtmlHelpers,
      ElektrineWeb.Live.AnnouncementCache,
      ElektrineWeb.Live.Helpers.PostStateHelpers,
      ElektrineWeb.Live.Hooks.PresenceEvents,
      ElektrineWeb.Live.NotificationHelpers,
      ElektrineWeb.Live.PostInteractions,
      Elektrine.Email.Mailbox,
      Elektrine.Email.MailboxAdapter
    ]
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
