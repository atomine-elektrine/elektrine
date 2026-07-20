defmodule ElektrineWeb.PageLive.About do
  use ElektrineWeb, :live_view

  alias Elektrine.EmailAddresses

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  @sections [
    %{
      title: "What it is",
      paras: [
        "Elektrine is a personal internet space for the parts of online life you want to keep close.",
        "Depending on the account, it can include communication, identity, search, storage, and personal tools."
      ]
    },
    %{
      title: "The vision",
      paras: [
        "Elektrine is designed to feel like one connected place instead of a pile of separate accounts and apps.",
        "The goal is a calmer, more portable home for messages, identity, connections, and everyday tools."
      ]
    },
    %{
      title: "Who is behind the project",
      paras: [
        "Elektrine is built and run by one person.",
        "Based in Detroit, Michigan."
      ]
    },
    %{
      title: "How it works",
      paras: [
        "Not every Elektrine account exposes the same features. Access can vary by local policy, trust, and configuration.",
        "Built with Elixir and Phoenix."
      ]
    },
    %{
      title: "Federation",
      paras: [
        "Social federation is built around ActivityPub.",
        "Chat federation uses Arblarg, a server-to-server protocol between domains.",
        "Optional Bluesky integration can connect public social posting to ATProto services."
      ]
    }
  ]

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "About", sections: @sections)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="pb-8">
        <.e_nav
          active_tab=""
          class="mb-6"
          current_user={@current_user}
          badge_counts={@e_nav_badge_counts}
        />

        <div>
          <header class="mb-8">
            <h1 class="text-3xl font-semibold tracking-tight">About Elektrine</h1>
          </header>

          <.card id="about-card" class="panel-card" body_class="p-0">
            <:body>
              <section
                :for={section <- @sections}
                class="border-b border-base-content/10 px-5 py-6 last:border-b-0 sm:px-7"
              >
                <h2 class="text-base font-semibold">{section.title}</h2>

                <p
                  :for={para <- section.paras}
                  class="mt-3 text-sm leading-relaxed text-base-content/70"
                >
                  {para}
                </p>
              </section>

              <section class="px-5 py-6 sm:px-7">
                <h2 class="text-base font-semibold">Contact</h2>

                <dl class="mt-4 space-y-2 text-sm">
                  <div class="flex gap-3">
                    <dt class="w-16 shrink-0 text-base-content/50">General</dt>
                    <dd>
                      <a href={EmailAddresses.mailto("welcome")} class="link link-hover text-primary">
                        {EmailAddresses.local("welcome")}
                      </a>
                    </dd>
                  </div>

                  <div class="flex gap-3">
                    <dt class="w-16 shrink-0 text-base-content/50">Support</dt>
                    <dd>
                      <a href={EmailAddresses.mailto("support")} class="link link-hover text-primary">
                        {EmailAddresses.local("support")}
                      </a>
                    </dd>
                  </div>

                  <div class="flex gap-3">
                    <dt class="w-16 shrink-0 text-base-content/50">Security</dt>
                    <dd>
                      <a href={EmailAddresses.mailto("security")} class="link link-hover text-primary">
                        {EmailAddresses.local("security")}
                      </a>
                    </dd>
                  </div>
                </dl>
              </section>
            </:body>
          </.card>
        </div>
      </div>
    </div>
    """
  end
end
