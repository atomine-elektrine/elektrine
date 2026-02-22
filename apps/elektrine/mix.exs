defmodule Elektrine.MixProject do
  use Mix.Project

  def project do
    [
      app: :elektrine,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: elixirc_options(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {Elektrine.Application, []},
      extra_applications: [:logger, :runtime_tools]
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
      Elektrine.Email,
      Elektrine.Email.Alias,
      Elektrine.Email.AttachmentStorage,
      Elektrine.Email.Cached,
      Elektrine.Email.HarakaClient,
      Elektrine.Email.Mailbox,
      Elektrine.Email.MailboxAdapter,
      Elektrine.Email.Message,
      Elektrine.Social,
      Elektrine.Social.FetchLinkPreviewWorker,
      Elektrine.Social.Hashtag,
      Elektrine.Social.LinkPreview,
      Elektrine.Social.LinkPreviewFetcher,
      Elektrine.Social.MessageVote,
      Elektrine.Social.Poll,
      Elektrine.Social.PollOption,
      Elektrine.Social.PostBoost,
      Elektrine.Social.PostLike,
      ElektrineWeb.Endpoint,
      ElektrineWeb.HarakaWebhookController,
      ElektrineWeb.Presence
    ]
  end

  defp deps do
    [
      {:phoenix, "== 1.8.3"},
      {:phoenix_ecto, "== 4.7.0"},
      {:ecto_sql, "== 3.13.4"},
      {:postgrex, "== 0.22.0"},
      {:phoenix_html, "== 4.3.0"},
      {:phoenix_live_reload, "== 1.6.2", only: :dev},
      {:phoenix_live_view, "== 1.1.24"},
      {:floki, "== 0.38.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "== 0.8.7"},
      {:esbuild, "== 0.10.0", runtime: Mix.env() == :dev},
      {:tailwind, "== 0.4.1", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "== 1.22.0"},
      {:finch, "== 0.21.0"},
      {:mail, "~> 0.5.1"},
      {:telemetry_metrics, "== 1.1.0"},
      {:telemetry_poller, "== 1.3.0"},
      {:gettext, "== 1.0.2"},
      {:jason, "== 1.4.4"},
      {:dns_cluster, "== 0.2.0"},
      {:bandit, "== 1.10.2"},
      {:bcrypt_elixir, "== 3.3.2"},
      {:argon2_elixir, "== 4.1.3"},
      {:plug_cowboy, "== 2.8.0"},
      {:gen_smtp, "== 1.3.0"},
      {:quantum, "== 3.5.3"},
      {:oban, "== 2.20.3"},
      {:oban_live_dashboard, "~> 0.1"},
      {:ex_aws, "== 2.6.1"},
      {:ex_aws_s3, "== 2.5.9"},
      {:sweet_xml, "== 0.7.5"},
      {:html_sanitize_ex, "== 1.4.4"},
      {:nimble_totp, "== 1.0.0"},
      {:wax_, "~> 0.6"},
      {:eqrcode, "== 0.2.1"},
      {:cachex, "== 4.1.1"},
      {:earmark, "== 1.4.48"},
      {:sentry, "== 11.0.4"},
      {:tzdata, "== 1.1.3"},
      {:image, "== 0.63.0"},
      {:html_entities, "~> 0.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:wallaby, "~> 0.30", only: :test, runtime: false},
      {:stripity_stripe, "~> 3.0"}
    ]
  end

  defp aliases do
    [
      setup: [
        "deps.get",
        "ecto.setup",
        "assets.setup",
        "assets.build",
        "cmd git config core.hooksPath ../../.githooks"
      ],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": [
        "cmd --cd assets npm install",
        "tailwind.install --if-missing",
        "esbuild.install --if-missing"
      ],
      "assets.build": ["tailwind elektrine", "esbuild elektrine"],
      "assets.deploy": [
        "tailwind elektrine --minify",
        "esbuild elektrine --minify",
        "phx.digest"
      ]
    ]
  end
end
