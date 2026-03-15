defmodule ElektrineWeb.PageLive.Contact do
  use ElektrineWeb, :live_view

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Contact")}
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="mx-auto max-w-7xl px-4 pb-8 sm:px-6 lg:px-8">
        <.z_nav active_tab="" class="mb-6" />

        <div id="contact-card" phx-hook="GlassCard" class="card glass-card shadow-xl">
          <div class="card-body">
            <h1 class="card-title text-3xl mb-6">Contact</h1>

            <div class="space-y-4">
              <div class="card bg-base-300">
                <div class="card-body">
                  <h3 class="font-semibold">General</h3>
                  <a href="mailto:welcome@elektrine.com" class="link link-primary">
                    welcome@elektrine.com
                  </a>
                </div>
              </div>

              <div class="card bg-base-300">
                <div class="card-body">
                  <h3 class="font-semibold">Support</h3>
                  <a href="mailto:support@elektrine.com" class="link link-primary">
                    support@elektrine.com
                  </a>
                </div>
              </div>

              <div class="card bg-base-300">
                <div class="card-body">
                  <h3 class="font-semibold">Security</h3>
                  <a href="mailto:security@elektrine.com" class="link link-primary">
                    security@elektrine.com
                  </a>
                </div>
              </div>

              <div class="card bg-base-300">
                <div class="card-body">
                  <h3 class="font-semibold">Privacy</h3>
                  <a href="mailto:privacy@elektrine.com" class="link link-primary">
                    privacy@elektrine.com
                  </a>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
