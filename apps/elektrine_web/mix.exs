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
      Phoenix.LiveReloader,
      Phoenix.LiveReloader.Socket,
      ElektrineSocialWeb.ActivityPubController,
      ElektrineEmailWeb.Admin.AliasesController,
      ElektrineChatWeb.Admin.ChatMessagesController,
      ElektrineEmailWeb.Admin.CustomDomainsController,
      ElektrineEmailWeb.Admin.MailboxesController,
      ElektrineEmailWeb.Admin.MessagesController,
      ElektrineVPNWeb.Admin.VPNController,
      ElektrineEmailWeb.API.AliasController,
      ElektrineChatWeb.API.ConversationController,
      ElektrineEmailWeb.API.EmailController,
      ElektrineChatWeb.API.ExtChatController,
      ElektrineEmailWeb.API.ExtContactsController,
      ElektrineEmailWeb.API.ExtEmailController,
      ElektrineSocialWeb.API.ExtSocialController,
      ElektrineEmailWeb.API.MailboxController,
      ElektrineChatWeb.API.MessageController,
      ElektrineChatWeb.API.ServerController,
      ElektrineSocialWeb.API.SocialController,
      ElektrineVPNWeb.API.VPNController,
      ElektrineEmailWeb.AttachmentController,
      ElektrineChatWeb.ChatLive.Index,
      ElektrineEmailWeb.ContactsLive.Index,
      ElektrineEmailWeb.DAV.AddressBookController,
      ElektrineDNSWeb.API.DNSController,
      ElektrineDNSWeb.DNSLive.Index,
      ElektrineSocialWeb.DiscussionsLive.Community,
      ElektrineSocialWeb.DiscussionsLive.Index,
      ElektrineSocialWeb.DiscussionsLive.Post,
      ElektrineSocialWeb.DiscussionsLive.Settings,
      ElektrineEmailWeb.EmailController,
      ElektrineEmailWeb.EmailLive.Compose,
      ElektrineEmailWeb.EmailLive.Index,
      ElektrineEmailWeb.EmailLive.Raw,
      ElektrineEmailWeb.EmailLive.Search,
      ElektrineEmailWeb.EmailLive.Settings,
      ElektrineEmailWeb.EmailLive.Show,
      ElektrineSocialWeb.ExternalInteractionController,
      ElektrineSocialWeb.GalleryLive.Index,
      ElektrineEmailWeb.HarakaWebhookController,
      ElektrineSocialWeb.HashtagLive.Show,
      ElektrineEmailWeb.JMAP.APIController,
      ElektrineEmailWeb.JMAP.BlobController,
      ElektrineEmailWeb.JMAP.EventSourceController,
      ElektrineEmailWeb.JMAP.SessionController,
      ElektrineSocialWeb.ListLive.Index,
      ElektrineSocialWeb.ListLive.Show,
      ElektrineSocialWeb.MastodonAPI.AccountController,
      ElektrineSocialWeb.MastodonAPI.AppController,
      ElektrineSocialWeb.MastodonAPI.InstanceController,
      ElektrineSocialWeb.MastodonAPI.OAuthController,
      ElektrineSocialWeb.MediaProxyController,
      ElektrineSocialWeb.NodeinfoController,
      ElektrineVPNWeb.PageLive.VPNPolicy,
      ElektrineSocialWeb.RemotePostLive.Show,
      ElektrineSocialWeb.RemoteUserLive.Show,
      ElektrineSocialWeb.TimelineLive.Index,
      ElektrineSocialWeb.TimelineLive.Post,
      ElektrineEmailWeb.UnsubscribeController,
      ElektrineEmailWeb.UnsubscribeLive.Show,
      ElektrineVPNWeb.VPNAPIController,
      ElektrineVPNWeb.VPNLive.Index,
      ElektrineSocialWeb.WebFingerController,
      ElektrineEmailWeb.WKDController,
      Elektrine.DNS,
      Elektrine.DNS.MailSecurity
    ]
  end

  defp deps do
    [
      internal_dep(:elektrine),
      internal_dep(:elektrine_password_manager)
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
