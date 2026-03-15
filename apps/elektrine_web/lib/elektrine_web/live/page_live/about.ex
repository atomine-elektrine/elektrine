defmodule ElektrineWeb.PageLive.About do
  use ElektrineWeb, :live_view

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "About")}
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="mx-auto max-w-7xl px-4 pb-8 sm:px-6 lg:px-8">
        <.z_nav active_tab="" class="mb-6" />

        <div id="about-card" phx-hook="GlassCard" class="card glass-card shadow-xl">
          <div class="card-body">
            <h1 class="card-title text-3xl mb-6">About Elektrine</h1>

            <div class="prose prose-lg max-w-none">
              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">What it is</h2>
                <p class="mb-4">
                  Elektrine is a modular platform for running internet services from one account.
                </p>
                <p>
                  Depending on the deployment, it can include email, chat, social, contacts, calendar, VPN, and vault features.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">The vision</h2>
                <p class="mb-4">
                  Elektrine is designed so operators can run multiple internet services together without splitting identity, accounts, and administration across separate systems.
                </p>
                <p>
                  For users, it should feel like one native product with one account, not a loose bundle of separate projects.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">How it is deployed</h2>
                <p class="mb-4">Based in Detroit, Michigan.</p>
                <p class="mb-4">
                  Not every Elektrine deployment exposes the same modules. Features can be enabled, disabled, or limited by local policy.
                </p>
                <p>Built with Elixir and Phoenix.</p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">Federation</h2>
                <p class="mb-4">
                  Social federation is built around ActivityPub.
                </p>
                <p class="mb-4">
                  Messaging federation uses Arblarg, a server-to-server chat protocol between domains.
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
                    <a href="mailto:welcome@elektrine.com" class="link link-primary">
                      welcome@elektrine.com
                    </a>
                  </p>
                  <p>
                    Support:
                    <a href="mailto:support@elektrine.com" class="link link-primary">
                      support@elektrine.com
                    </a>
                  </p>
                  <p>
                    Security:
                    <a href="mailto:security@elektrine.com" class="link link-primary">
                      security@elektrine.com
                    </a>
                  </p>
                </div>
              </section>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
