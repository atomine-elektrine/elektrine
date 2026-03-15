defmodule ElektrineWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :elektrine_web,
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
      ElektrinePasswordManagerWeb.API.VaultController,
      ElektrinePasswordManagerWeb.VaultLive,
      ElektrineWeb.ActivityPubController,
      ElektrineWeb.Admin.AliasesController,
      ElektrineWeb.Admin.ChatMessagesController,
      ElektrineWeb.Admin.CustomDomainsController,
      ElektrineWeb.Admin.MailboxesController,
      ElektrineWeb.Admin.MessagesController,
      ElektrineWeb.Admin.VPNController,
      ElektrineWeb.API.AliasController,
      ElektrineWeb.API.ConversationController,
      ElektrineWeb.API.EmailController,
      ElektrineWeb.API.ExtChatController,
      ElektrineWeb.API.ExtContactsController,
      ElektrineWeb.API.ExtEmailController,
      ElektrineWeb.API.ExtSocialController,
      ElektrineWeb.API.MailboxController,
      ElektrineWeb.API.MessageController,
      ElektrineWeb.API.ServerController,
      ElektrineWeb.API.SocialController,
      ElektrineWeb.API.VPNController,
      ElektrineWeb.AttachmentController,
      ElektrineWeb.ChatLive.Index,
      ElektrineWeb.ContactsLive.Index,
      ElektrineWeb.DAV.AddressBookController,
      ElektrineWeb.DiscussionsLive.Community,
      ElektrineWeb.DiscussionsLive.Index,
      ElektrineWeb.DiscussionsLive.Post,
      ElektrineWeb.DiscussionsLive.Settings,
      ElektrineWeb.EmailController,
      ElektrineWeb.EmailLive.Compose,
      ElektrineWeb.EmailLive.Index,
      ElektrineWeb.EmailLive.Raw,
      ElektrineWeb.EmailLive.Search,
      ElektrineWeb.EmailLive.Settings,
      ElektrineWeb.EmailLive.Show,
      ElektrineWeb.ExternalInteractionController,
      ElektrineWeb.GalleryLive.Index,
      ElektrineWeb.HarakaWebhookController,
      ElektrineWeb.HashtagLive.Show,
      ElektrineWeb.JMAP.APIController,
      ElektrineWeb.JMAP.BlobController,
      ElektrineWeb.JMAP.EventSourceController,
      ElektrineWeb.JMAP.SessionController,
      ElektrineWeb.ListLive.Index,
      ElektrineWeb.ListLive.Show,
      ElektrineWeb.MastodonAPI.AccountController,
      ElektrineWeb.MastodonAPI.AppController,
      ElektrineWeb.MastodonAPI.InstanceController,
      ElektrineWeb.MastodonAPI.OAuthController,
      ElektrineWeb.MediaProxyController,
      ElektrineWeb.NodeinfoController,
      ElektrineWeb.PageLive.VPNPolicy,
      ElektrineWeb.RemotePostLive.Show,
      ElektrineWeb.RemoteUserLive.Show,
      ElektrineWeb.TimelineLive.Index,
      ElektrineWeb.TimelineLive.Post,
      ElektrineWeb.UnsubscribeController,
      ElektrineWeb.UnsubscribeLive.Show,
      ElektrineWeb.VPNAPIController,
      ElektrineWeb.VPNLive.Index,
      ElektrineWeb.WebFingerController,
      ElektrineWeb.WKDController
    ]
  end

  defp deps do
    [
      internal_dep(:elektrine)
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
