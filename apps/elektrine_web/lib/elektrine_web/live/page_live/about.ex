defmodule ElektrineWeb.PageLive.About do
  use ElektrineWeb, :live_view

  alias Elektrine.EmailAddresses

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "About")}
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="mx-auto max-w-7xl px-4 pb-8 sm:px-6 lg:px-8">
        <.e_nav active_tab="" class="mb-6" current_user={@current_user} />

        <.card id="about-card">
          <:body>
            <h1 class="card-title text-3xl mb-6">About Elektrine</h1>

            <div class="prose prose-lg max-w-none">
              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">What it is</h2>
                <p class="mb-4">
                  Elektrine is a personal internet space for the parts of online life you want to keep close.
                </p>
                <p>
                  Depending on the account, it can include communication, identity, search, storage, and personal tools.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">The vision</h2>
                <p class="mb-4">
                  Elektrine is designed to feel like one connected place instead of a pile of separate accounts and apps.
                </p>
                <p>
                  The goal is a calmer, more portable home for messages, identity, connections, and everyday tools.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">Who is behind the project</h2>
                <p class="mb-4">
                  Elektrine is built and run by one person.
                </p>
                <p>Based in Detroit, Michigan.</p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">How it works</h2>
                <p class="mb-4">
                  Not every Elektrine account exposes the same features. Access can vary by local policy, trust, and configuration.
                </p>
                <p>Built with Elixir and Phoenix.</p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">Federation</h2>
                <p class="mb-4">
                  Social federation is built around ActivityPub.
                </p>
                <p class="mb-4">
                  Chat federation uses Arblarg, a server-to-server protocol between domains.
                </p>
                <p>
                  Optional Bluesky integration can connect public social posting to ATProto services.
                </p>
              </section>

              <section>
                <h2 class="text-2xl font-semibold mb-4">Contact</h2>
                <p>For questions, support, or security issues:</p>
                <div class="mt-4 space-y-2">
                  <p>
                    General:
                    <a href={EmailAddresses.mailto("welcome")} class="link link-primary">
                      {EmailAddresses.local("welcome")}
                    </a>
                  </p>
                  <p>
                    Support:
                    <a href={EmailAddresses.mailto("support")} class="link link-primary">
                      {EmailAddresses.local("support")}
                    </a>
                  </p>
                  <p>
                    Security:
                    <a href={EmailAddresses.mailto("security")} class="link link-primary">
                      {EmailAddresses.local("security")}
                    </a>
                  </p>
                </div>
              </section>
            </div>
          </:body>
        </.card>
      </div>
    </div>
    """
  end
end
