defmodule ElektrineWeb.PageLive.FAQ do
  use ElektrineWeb, :live_view

  alias Elektrine.EmailAddresses

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "FAQ", groups: groups())}
  end

  defp groups do
    domains =
      Enum.map_join(Elektrine.Domains.supported_email_domains(), ", ", &("username@" <> &1))

    [
      %{
        title: "General",
        entries: [
          {"What is Elektrine?",
           "Elektrine is a personal internet space for messages, identity, search, storage, and everyday tools."},
          {"Are the same features available on every deployment?",
           "No. Deployments can compile in different modules and apply different local policies."},
          {"Do I need separate accounts for different features?",
           "No. One account works across the modules enabled on the same deployment."},
          {"Can registration be invite-only?",
           "Yes. Registration policy depends on the deployment."}
        ]
      },
      %{
        title: "Vision and Federation",
        entries: [
          {"What is the vision for Elektrine?",
           "Elektrine is meant to give people one connected place for the parts of online life they want to keep close, without making it feel like a stack of unrelated products."},
          {"What does federation mean in Elektrine?",
           "Federation means an Elektrine deployment can exchange activity with other servers instead of acting as a closed silo. The exact behavior depends on which modules are enabled."},
          {"Which federated protocols are supported?",
           "ActivityPub powers the federated social web surface. Chat federation uses Arblarg between domains. Optional Bluesky integration can connect public social posting to ATProto services."}
        ]
      },
      %{
        title: "Modes",
        entries: [
          {"What is Portal?",
           "Portal is the dashboard for your account. It brings together activity from the modules enabled on the deployment."},
          {"What is Chat?",
           "Chat is the messaging area for direct conversations and group conversations."},
          {"What is Timeline?", "Timeline is the social feed for posts and updates."},
          {"What are Communities?",
           "Communities are topic-based spaces for longer discussion and shared moderation."},
          {"What is Gallery?",
           "Gallery is the media-focused view of the social side of Elektrine."},
          {"What are Friends?",
           "Friends is the area for managing person-to-person connections on the platform."},
          {"What is Nerve?",
           "Nerve stores encrypted entries tied to your account when the nerve module is enabled."}
        ]
      },
      %{
        title: "Email and Integrations",
        entries: [
          {"Which client and integration protocols are supported?",
           "When the relevant modules are enabled, Elektrine supports IMAP, POP3, SMTP, JMAP, CardDAV, CalDAV, and API tokens for integrations."},
          {"What email addresses are available?",
           "If email is enabled, local mailboxes use the domains configured for this deployment: #{domains}."}
        ]
      },
      %{
        title: "Support",
        entries: [
          {"How do I get help?",
           "Support: #{EmailAddresses.local("support")}. Security: #{EmailAddresses.local("security")}. Privacy: #{EmailAddresses.local("privacy")}."}
        ]
      }
    ]
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="mx-auto max-w-7xl px-4 pb-8 sm:px-6 lg:px-8">
        <.e_nav active_tab="" class="mb-6" current_user={@current_user} />

        <div>
          <header class="mb-8">
            <h1 class="text-3xl font-semibold tracking-tight">
              Frequently Asked Questions
            </h1>
          </header>

          <div id="faq-items" class="space-y-6">
            <section :for={group <- @groups}>
              <h2 class="mb-3 text-base font-semibold">{group.title}</h2>

              <.card class="panel-card" body_class="p-0">
                <:body>
                  <div
                    :for={{question, answer} <- group.entries}
                    class="collapse collapse-arrow rounded-none border-b border-base-content/10 last:border-b-0"
                  >
                    <input type="checkbox" />
                    <div class="collapse-title px-5 text-sm font-medium sm:px-7">
                      {question}
                    </div>
                    <div class="collapse-content px-5 sm:px-7">
                      <p class="text-sm leading-relaxed text-base-content/70">{answer}</p>
                    </div>
                  </div>
                </:body>
              </.card>
            </section>
          </div>

          <p class="mt-8 text-sm text-base-content/60">
            Still have questions?
            <a href={EmailAddresses.mailto("support")} class="link link-hover text-primary">
              {EmailAddresses.local("support")}
            </a>
          </p>
        </div>
      </div>
    </div>
    """
  end
end
