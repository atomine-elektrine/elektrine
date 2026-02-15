defmodule ElektrineWeb.PageLive.Home do
  use ElektrineWeb, :live_view

  import Ecto.Query

  on_mount({ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user})

  def mount(_params, _session, socket) do
    # Use cached platform stats to avoid expensive queries on every page load
    {:ok, cached_stats} =
      Elektrine.AppCache.get_platform_stats(fn ->
        %{
          stats: %{
            users: Elektrine.Repo.aggregate(Elektrine.Accounts.User, :count, :id),
            emails: Elektrine.Repo.aggregate(Elektrine.Email.Message, :count, :id),
            posts: get_post_count()
          },
          federation: %{
            remote_actors: get_remote_actor_count(),
            instances: get_instance_count()
          }
        }
      end)

    # Active users is real-time, don't cache
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

  def render(assigns) do
    ~H"""
    <script type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "WebSite",
        "name": "Elektrine",
        "url": "https://elektrine.com"
      }
    </script>

    <div class="min-h-screen text-white flex flex-col items-center justify-center px-6 relative z-10">
      <div class="text-center">
        <img src="/images/logo.svg" alt="Elektrine" class="h-24 sm:h-32 w-auto mx-auto mb-8" />
        <p class="text-xl sm:text-2xl font-light opacity-60 mb-4">
          {gettext("Dark energy")}
        </p>
        <p class="text-sm opacity-30 mb-12 tracking-widest">
          EMAIL / VPN / SOCIAL / API / BUSINESS
        </p>
        <div class="flex flex-col sm:flex-row items-center justify-center gap-4">
          <%= if @current_user do %>
            <.link href={~p"/overview"} class="btn btn-primary btn-lg min-w-[140px]">
              {gettext("Overview")}
            </.link>
            <.link
              href={~p"/email"}
              class="btn btn-ghost btn-lg text-white/60 hover:text-white min-w-[140px]"
            >
              {gettext("Email")}
            </.link>
            <.link
              href={~p"/account"}
              class="btn btn-ghost btn-lg text-white/60 hover:text-white min-w-[140px]"
            >
              {gettext("Account")}
            </.link>
            <.link
              href={~p"/logout"}
              method="delete"
              class="btn btn-error btn-lg min-w-[140px]"
            >
              {gettext("Sign out")}
            </.link>
          <% else %>
            <.link href={~p"/register"} class="btn btn-primary btn-lg min-w-[160px]">
              {gettext("Sign up")}
            </.link>
            <.link
              href={~p"/login"}
              class="btn btn-ghost btn-lg text-white/60 hover:text-white min-w-[160px]"
            >
              {gettext("Sign in")}
            </.link>
          <% end %>
        </div>
      </div>
      
    <!-- Stats - bottom -->
      <div class="absolute bottom-8 left-0 right-0 flex flex-col items-center gap-2">
        <div class="flex items-center gap-6 text-xs font-mono text-white/30">
          <span>{format_number(@stats.users)} users</span>
          <span>{format_number(@stats.emails)} emails</span>
          <span>{format_number(@stats.posts)} posts</span>
        </div>
        <div class="flex items-center gap-6 text-xs font-mono text-white/20">
          <span>{format_number(@federation.remote_actors)} remote users</span>
          <span>{format_number(@federation.instances)} instances</span>
          <span>{@sys.active_users} online</span>
        </div>
      </div>
    </div>
    """
  end

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

  defp get_active_user_count do
    five_minutes_ago = DateTime.add(DateTime.utc_now(), -300, :second)

    Elektrine.Repo.one(
      from(u in Elektrine.Accounts.User,
        where: u.last_seen_at > ^five_minutes_ago,
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
