defmodule ElektrineWeb.PageLive.Home do
  use ElektrineWeb, :live_view

  import Ecto.Query
  require Logger
  alias Elektrine.Platform.Modules
  alias ElektrineWeb.Platform.Integrations

  on_mount({ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user})

  def mount(_params, _session, socket) do
    cached_stats = load_platform_stats()

    sys = %{
      active_users: get_active_user_count()
    }

    {:ok,
     assign(socket,
       page_title: "Home",
       stats: cached_stats.stats,
       federation: cached_stats.federation,
       sys: sys
     ), layout: false}
  end

  @doc false
  def load_platform_stats(cache_getter \\ &Elektrine.AppCache.get_platform_stats/1) do
    case cache_getter.(fn ->
           %{
             stats: %{
               users: Elektrine.Repo.aggregate(Elektrine.Accounts.User, :count, :id),
               emails: Integrations.email_message_count(),
               posts: get_post_count()
             },
             federation: %{
               remote_actors: get_remote_actor_count(),
               instances: get_instance_count()
             }
           }
         end) do
      {:ok, cached_stats} ->
        cached_stats

      {:error, reason} ->
        Logger.warning("Home platform stats cache fetch failed: #{inspect(reason)}")
        default_platform_stats()
    end
  end

  def render(assigns) do
    ~H"""
    <script type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "WebSite",
        "name": "Elektrine",
        "url": "#{Domains.public_base_url()}"
      }
    </script>

    <div class="relative min-h-screen overflow-hidden text-base-content">
      <div class="pointer-events-none absolute inset-0 bg-[radial-gradient(circle_at_top,rgba(168,85,247,0.12),transparent_34%),radial-gradient(circle_at_82%_18%,rgba(249,115,22,0.08),transparent_20%)]">
      </div>

      <div class="relative mx-auto flex min-h-screen max-w-7xl flex-col px-6 py-6 sm:px-8 lg:px-10">
        <header class="flex items-center justify-between gap-4 py-2">
          <a href="/" class="inline-flex items-center">
            <img src="/images/logo.svg" alt="Elektrine" class="h-8 w-auto sm:h-9" />
          </a>
        </header>

        <main class="flex flex-1 items-center py-8 lg:py-10">
          <div class="grid w-full gap-6 lg:grid-cols-[minmax(0,1fr)_24rem]">
            <section class="card border border-base-300 bg-base-100/85 shadow-sm backdrop-blur-sm">
              <div class="card-body gap-6 p-6 sm:p-8">
                <div class="space-y-4">
                  <p class="text-xs uppercase tracking-[0.24em] opacity-60">
                    For operators
                  </p>
                  <h1 class="text-4xl font-semibold tracking-tight text-white sm:text-5xl lg:text-6xl">
                    Software you can own.
                  </h1>
                  <p class="max-w-xl text-base leading-7 text-base-content/70 sm:text-lg">
                    Elektrine is a modular platform for operators who want to run internet
                    services under their own control.
                  </p>
                </div>

                <div class="flex flex-wrap items-center gap-3">
                  <%= if @current_user do %>
                    <.link href={~p"/overview"} class="btn btn-primary btn-lg">
                      {gettext("Overview")}
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
                    <.link href={~p"/login"} class="btn btn-ghost btn-lg">
                      {gettext("Sign in")}
                    </.link>
                  <% end %>
                </div>

                <div class="flex flex-wrap items-center gap-4 text-sm text-base-content/60">
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
                </div>
              </div>
            </section>

            <section class="card border border-base-300 bg-base-100/85 shadow-sm backdrop-blur-sm">
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
                          <p class="text-sm font-medium text-white">{module.name}</p>
                          <p class="text-xs uppercase tracking-[0.18em] opacity-50">
                            {module.detail}
                          </p>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            </section>
          </div>
        </main>

        <footer class="pb-4">
          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <%= for stat <- home_stats(@stats, @federation, @sys) do %>
              <div class="rounded-lg border border-base-300 bg-base-100/80 px-4 py-3 shadow-sm backdrop-blur-sm">
                <p class="text-xs uppercase tracking-wide opacity-60">{stat.label}</p>
                <p class="mt-2 text-2xl font-semibold text-white">{stat.value}</p>
              </div>
            <% end %>
          </div>
        </footer>
      </div>
    </div>
    """
  end

  defp home_stats(stats, federation, sys) do
    [
      %{label: "Users", value: format_number(stats.users)},
      %{label: "Emails", value: format_number(stats.emails)},
      %{label: "Instances", value: format_number(federation.instances)},
      %{label: "Connected", value: format_number(sys.active_users)}
    ]
  end

  defp home_modules do
    [
      %{icon: "hero-envelope-mini", name: "Email", detail: "IMAP / POP3 / SMTP / JMAP"},
      %{
        icon: "hero-finger-print-mini",
        name: "Accounts",
        detail: "Domains / identity / passkeys"
      },
      %{icon: "hero-chat-bubble-left-right-mini", name: "Chat", detail: "Arblarg"},
      %{icon: "hero-sparkles-mini", name: "Social", detail: "ActivityPub / Bluesky"},
      %{icon: "hero-shield-check-mini", name: "VPN", detail: "WireGuard"},
      %{icon: "hero-key-mini", name: "Passwords", detail: "Vault"}
    ]
    |> Enum.filter(fn module ->
      case module.name do
        "Email" -> Modules.enabled?(:email)
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

  defp get_post_count do
    Elektrine.Repo.one(
      from(m in Elektrine.Messaging.Message,
        join: c in Elektrine.Messaging.Conversation,
        on: m.conversation_id == c.id,
        where: c.type == "timeline",
        select: count(m.id)
      )
    ) || 0
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)

  defp default_platform_stats do
    %{
      stats: %{
        users: 0,
        emails: 0,
        posts: 0
      },
      federation: %{
        remote_actors: 0,
        instances: 0
      }
    }
  end

  defp get_active_user_count do
    five_minutes_ago = DateTime.add(DateTime.utc_now(), -300, :second)

    Elektrine.Repo.one(
      from(u in Elektrine.Accounts.User,
        where:
          u.last_seen_at > ^five_minutes_ago or
            u.last_imap_access > ^five_minutes_ago or
            u.last_pop3_access > ^five_minutes_ago,
        select: count(u.id)
      )
    ) || 0
  end

  defp get_remote_actor_count do
    Elektrine.Repo.one(
      from(a in Elektrine.ActivityPub.Actor,
        where: a.actor_type == "Person",
        select: count(a.id)
      )
    ) || 0
  end

  defp get_instance_count do
    Elektrine.Repo.one(
      from(a in Elektrine.ActivityPub.Actor,
        select: count(a.domain, :distinct)
      )
    ) || 0
  end
end
