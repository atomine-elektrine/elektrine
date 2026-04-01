defmodule ElektrineWeb.PageLive.Contact do
  use ElektrineWeb, :live_view

  alias Elektrine.EmailAddresses

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Contact")}
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="mx-auto max-w-7xl px-4 pb-8 sm:px-6 lg:px-8">
        <.e_nav active_tab="" class="mb-6" current_user={@current_user} />

        <div id="contact-card" class="card panel-card">
          <div class="card-body">
            <h1 class="card-title text-3xl mb-6">Contact</h1>

            <div class="space-y-4">
              <div class="card bg-base-300">
                <div class="card-body">
                  <h3 class="font-semibold">General</h3>
                  <a href={EmailAddresses.mailto("welcome")} class="link link-primary">
                    {EmailAddresses.local("welcome")}
                  </a>
                </div>
              </div>

              <div class="card bg-base-300">
                <div class="card-body">
                  <h3 class="font-semibold">Support</h3>
                  <a href={EmailAddresses.mailto("support")} class="link link-primary">
                    {EmailAddresses.local("support")}
                  </a>
                </div>
              </div>

              <div class="card bg-base-300">
                <div class="card-body">
                  <h3 class="font-semibold">Security</h3>
                  <a href={EmailAddresses.mailto("security")} class="link link-primary">
                    {EmailAddresses.local("security")}
                  </a>
                </div>
              </div>

              <div class="card bg-base-300">
                <div class="card-body">
                  <h3 class="font-semibold">Privacy</h3>
                  <a href={EmailAddresses.mailto("privacy")} class="link link-primary">
                    {EmailAddresses.local("privacy")}
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
