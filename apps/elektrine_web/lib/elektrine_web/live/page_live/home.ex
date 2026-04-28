defmodule ElektrineWeb.PageLive.Home do
  use ElektrineWeb, :live_view

  require Logger

  alias Elektrine.Platform.Modules

  on_mount({ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user})

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Home"), layout: false}
  end

  def render(assigns) do
    ~H"""
    <script nonce={ElektrineWeb.Plugs.SecurityHeaders.script_nonce()} type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "WebSite",
        "name": "Elektrine",
        "url": "#{Domains.public_base_url()}"
      }
    </script>

    <div class="relative min-h-screen overflow-hidden text-base-content">
      <div
        class="pointer-events-none absolute inset-0"
        style="background: radial-gradient(circle at top, color-mix(in srgb, var(--color-primary) 10%, transparent), transparent 34%), radial-gradient(circle at 82% 18%, color-mix(in srgb, var(--color-secondary) 8%, transparent), transparent 20%);"
      >
      </div>

      <div class="relative mx-auto flex min-h-screen max-w-7xl flex-col px-6 py-6 sm:px-8 lg:px-10">
        <header class="flex items-center justify-between gap-4 py-2">
          <.link navigate={~p"/"} class="inline-flex items-center">
            <img src="/images/logo.svg" alt="Elektrine" class="h-8 w-auto sm:h-9" />
          </.link>
        </header>

        <main class="flex flex-1 items-center py-8 lg:py-10">
          <div class="grid w-full items-start gap-6 lg:grid-cols-[minmax(0,1.1fr)_23rem]">
            <section class="card border border-base-300 bg-base-200/80">
              <div class="card-body gap-6 p-6 sm:p-8 lg:p-10">
                <div class="space-y-4">
                  <div class="inline-flex items-center rounded-full border border-base-300 bg-base-200/50 px-3 py-1 text-[11px] font-semibold uppercase tracking-[0.24em] text-base-content/65">
                    Doctrine
                  </div>
                  <div class="space-y-4">
                    <h1 class="max-w-3xl text-4xl font-semibold tracking-tight text-base-content sm:text-5xl lg:text-[3.75rem] lg:leading-[1.02] text-balance">
                      Software for sovereignty.
                    </h1>
                    <p class="max-w-2xl text-base leading-7 text-base-content/72 sm:text-lg">
                      Elektrine is a modular platform for people who want to run communications,
                      identity, and infrastructure under their own control.
                    </p>
                  </div>
                </div>

                <div class="flex flex-wrap items-center gap-3">
                  <%= if @current_user do %>
                    <.link href={~p"/portal"} class="btn btn-primary btn-lg">
                      {gettext("Portal")}
                    </.link>
                    <%= if Modules.enabled?(:email) do %>
                      <.link href={~p"/email"} class="btn btn-ghost btn-lg">
                        {gettext("Email")}
                      </.link>
                    <% end %>
                    <.link href={~p"/account"} class="btn btn-ghost btn-lg">
                      {gettext("Account")}
                    </.link>
                    <.link href={~p"/logout"} method="delete" class="btn btn-error btn-lg">
                      {gettext("Sign out")}
                    </.link>
                  <% else %>
                    <.link href={~p"/register"} class="btn btn-primary btn-lg">
                      {gettext("Sign up")}
                    </.link>
                    <.link href={Elektrine.Paths.login_path()} class="btn btn-ghost btn-lg">
                      {gettext("Sign in")}
                    </.link>
                  <% end %>
                </div>

                <div class="flex flex-wrap items-center gap-4 border-t border-base-300/80 pt-5 text-sm text-base-content/60">
                  <.link
                    href={github_repo_url()}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex items-center gap-2 hover:text-base-content"
                  >
                    <.icon name="hero-code-bracket-mini" class="h-4 w-4" />
                    <span>GitHub</span>
                  </.link>
                  <.link
                    href={github_releases_url()}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex items-center gap-2 hover:text-base-content"
                  >
                    <.icon name="hero-arrow-down-tray-mini" class="h-4 w-4" />
                    <span>Releases</span>
                  </.link>
                  <.link
                    href={github_issues_url()}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex items-center gap-2 hover:text-base-content"
                  >
                    <.icon name="hero-exclamation-circle-mini" class="h-4 w-4" />
                    <span>Issues</span>
                  </.link>
                  <.link
                    href={~p"/canary"}
                    class="inline-flex items-center gap-2 hover:text-base-content"
                  >
                    <.icon name="hero-shield-check-mini" class="h-4 w-4" />
                    <span>Canary</span>
                  </.link>
                </div>
              </div>
            </section>

            <section class="space-y-4">
              <div class="card border border-base-300 bg-base-200/80">
                <div class="card-body gap-3 p-4 sm:p-5">
                  <p class="text-xs uppercase tracking-[0.22em] opacity-60">Principles</p>
                  <div class="space-y-3">
                    <div class="rounded-lg border border-base-300 bg-base-200/45 px-4 py-3">
                      <div class="text-xs uppercase tracking-[0.18em] opacity-50">Ownership</div>
                      <div class="mt-1 text-sm font-medium text-base-content">Host it yourself</div>
                    </div>
                    <div class="rounded-lg border border-base-300 bg-base-200/45 px-4 py-3">
                      <div class="text-xs uppercase tracking-[0.18em] opacity-50">Composition</div>
                      <div class="mt-1 text-sm font-medium text-base-content">
                        Compose only what you need
                      </div>
                    </div>
                    <div class="rounded-lg border border-base-300 bg-base-200/45 px-4 py-3">
                      <div class="text-xs uppercase tracking-[0.18em] opacity-50">Identity</div>
                      <div class="mt-1 text-sm font-medium text-base-content">
                        Accounts and domains stay yours
                      </div>
                    </div>
                  </div>
                </div>
              </div>

              <div class="card border border-base-300 bg-base-200/80">
                <div class="card-body gap-4 p-4 sm:p-5">
                  <p class="text-xs uppercase tracking-[0.22em] opacity-60">Modules</p>

                  <div class="space-y-2">
                    <%= for module <- home_modules() do %>
                      <div class="flex items-center rounded-lg border border-base-300 bg-base-200/45 px-3 py-3">
                        <div class="flex items-center gap-3">
                          <div class="rounded-lg border border-base-300 bg-base-200 p-2">
                            <.icon name={module.icon} class="h-4 w-4 opacity-80" />
                          </div>
                          <div>
                            <p class="text-sm font-medium text-base-content">{module.name}</p>
                            <p class="text-xs uppercase tracking-[0.18em] opacity-50">
                              {module.detail}
                            </p>
                          </div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            </section>
          </div>
        </main>
      </div>
    </div>
    """
  end

  defp home_modules do
    [
      %{icon: "hero-envelope-mini", name: "Email", detail: "IMAP / POP3 / SMTP / JMAP"},
      %{
        icon: "hero-finger-print-mini",
        name: "Accounts",
        detail: "Domains / identity / auth"
      },
      %{icon: "hero-globe-alt-mini", name: "DNS", detail: "Authoritative / recursive"},
      %{icon: "hero-chat-bubble-left-right-mini", name: "Chat", detail: "Arblarg"},
      %{icon: "hero-sparkles-mini", name: "Social", detail: "ActivityPub / ATProto"},
      %{icon: "hero-shield-check-mini", name: "VPN", detail: "WireGuard"},
      %{icon: "hero-key-mini", name: "Passwords", detail: "Vault"}
    ]
    |> Enum.filter(fn module ->
      case module.name do
        "Email" -> Modules.enabled?(:email)
        "DNS" -> Modules.enabled?(:dns)
        "Chat" -> Modules.enabled?(:chat)
        "Social" -> Modules.enabled?(:social)
        "VPN" -> Modules.enabled?(:vpn)
        "Passwords" -> Modules.enabled?(:vault)
        _ -> true
      end
    end)
  end

  defp github_repo_url, do: "https://github.com/atomine-elektrine/elektrine"

  defp github_releases_url, do: "https://github.com/atomine-elektrine/elektrine/releases"

  defp github_issues_url, do: "https://github.com/atomine-elektrine/elektrine/issues"

  def load_platform_stats(cache_fetch \\ &Elektrine.AppCache.get_platform_stats/1) do
    case cache_fetch.(fn -> default_platform_stats() end) do
      {:ok, stats} ->
        stats

      stats when is_map(stats) ->
        stats

      {:error, reason} ->
        Logger.warning("Home platform stats cache fetch failed: #{Exception.message(reason)}")
        default_platform_stats()
    end
  end

  defp default_platform_stats do
    %{
      stats: %{users: 0, emails: 0, posts: 0},
      federation: %{remote_actors: 0, instances: 0}
    }
  end
end
