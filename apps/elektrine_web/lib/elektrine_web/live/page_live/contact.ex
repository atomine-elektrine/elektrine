defmodule ElektrineWeb.PageLive.Contact do
  use ElektrineWeb, :live_view

  alias Elektrine.EmailAddresses

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  @channels [
    %{label: "General", local: "welcome", icon: "hero-envelope"},
    %{label: "Support", local: "support", icon: "hero-lifebuoy"},
    %{label: "Security", local: "security", icon: "hero-shield-check"},
    %{label: "Privacy", local: "privacy", icon: "hero-lock-closed"}
  ]

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Contact", channels: @channels)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="mx-auto max-w-7xl px-4 pb-8 sm:px-6 lg:px-8">
        <.e_nav active_tab="" class="mb-6" current_user={@current_user} />

        <div>
          <header class="mb-8">
            <h1 class="text-3xl font-semibold tracking-tight">Contact</h1>
          </header>

          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <a
              :for={channel <- @channels}
              href={EmailAddresses.mailto(channel.local)}
              class="group rounded-box border border-base-content/10 bg-base-200/20 p-5 transition-colors hover:border-base-content/20 hover:bg-base-200/40"
            >
              <div class="flex items-center gap-2">
                <.icon name={channel.icon} class="h-4 w-4 text-base-content/60" />
                <span class="text-sm font-semibold">{channel.label}</span>
              </div>

              <p class="mt-3 break-all text-sm font-medium text-primary group-hover:underline">
                {EmailAddresses.local(channel.local)}
              </p>
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
