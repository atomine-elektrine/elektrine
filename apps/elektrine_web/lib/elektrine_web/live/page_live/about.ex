defmodule ElektrineWeb.PageLive.About do
  use ElektrineWeb, :live_view

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "About")}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <div class="container mx-auto px-4 py-8 max-w-4xl">
        <div id="about-card" phx-hook="GlassCard" class="card glass-card shadow-xl">
          <div class="card-body">
            <h1 class="card-title text-3xl mb-6">About Elektrine</h1>

            <div class="prose prose-lg max-w-none">
              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">What is Elektrine</h2>
                <p class="mb-4">
                  A unified platform for communication and content. One account for all your online activities.
                </p>
                <p class="text-sm opacity-70">
                  Currently: Email, social networking, discussions, and profiles. More features coming.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">Who Are We</h2>
                <p class="mb-4">Based in Detroit, Michigan.</p>
                <p class="mb-4">Hosted in the United States.</p>
                <p>Built with Elixir/Phoenix and Haraka.</p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">Contact Us</h2>
                <p>We value your feedback and are here to help with any questions or concerns.</p>
                <div class="mt-4 space-y-2">
                  <p>
                    General inquiries:
                    <a href="mailto:welcome@elektrine.com" class="link link-primary">
                      welcome@elektrine.com
                    </a>
                  </p>
                  <p>
                    Technical support:
                    <a href="mailto:support@elektrine.com" class="link link-primary">
                      support@elektrine.com
                    </a>
                  </p>
                  <p>
                    Security concerns:
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
