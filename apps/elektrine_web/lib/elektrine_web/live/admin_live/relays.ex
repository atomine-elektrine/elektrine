defmodule ElektrineWeb.AdminLive.Relays do
  @moduledoc """
  Admin LiveView for managing ActivityPub relay subscriptions.
  """
  use ElektrineWeb, :live_view

  alias Elektrine.ActivityPub.Relay

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_user] && socket.assigns.current_user.is_admin do
      {:ok,
       socket
       |> assign(:page_title, "ActivityPub Relay Management")
       |> assign(:show_add_modal, false)
       |> assign(:relay_url, "")
       |> assign(:page, 1)
       |> assign(:per_page, 25)
       |> assign(:adding, false)
       |> load_relays()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    end
  end

  defp load_relays(socket) do
    page = socket.assigns[:page] || 1
    per_page = socket.assigns[:per_page] || 25
    page_data = Relay.paginate_subscriptions(page, per_page)

    socket
    |> assign(:subscriptions, page_data.entries)
    |> assign(:subscription_urls, Relay.subscribed_relay_uris())
    |> assign(:page, page_data.page)
    |> assign(:total_pages, page_data.total_pages)
    |> assign(:total_count, page_data.total_count)
    |> assign(:stats, Relay.subscription_stats())
  end

  @impl true
  def handle_event("show_add_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_add_modal, true)
     |> assign(:relay_url, "")}
  end

  def handle_event("close_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_add_modal, false)
     |> assign(:adding, false)}
  end

  def handle_event("update_relay_url", %{"value" => url}, socket) do
    {:noreply, assign(socket, :relay_url, url)}
  end

  def handle_event("subscribe", %{"relay_url" => relay_url}, socket) do
    relay_url = String.trim(relay_url)

    if Elektrine.Strings.present?(relay_url) do
      socket = assign(socket, :adding, true)

      case Relay.subscribe(relay_url, socket.assigns.current_user.id) do
        {:ok, _subscription} ->
          {:noreply,
           socket
           |> load_relays()
           |> assign(:show_add_modal, false)
           |> assign(:adding, false)
           |> put_flash(:info, "Subscription request sent to #{relay_url}")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:adding, false)
           |> put_flash(:error, "Failed to subscribe: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Please enter a relay URL")}
    end
  end

  def handle_event("unsubscribe", %{"uri" => relay_uri}, socket) do
    case Relay.unsubscribe(relay_uri) do
      {:ok, :unfollowed} ->
        {:noreply,
         socket
         |> load_relays()
         |> put_flash(:info, "Unsubscribed from #{relay_uri}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to unsubscribe: #{inspect(reason)}")}
    end
  end

  def handle_event("force_delete", %{"uri" => relay_uri}, socket) do
    case Relay.force_delete(relay_uri) do
      {:ok, :deleted} ->
        {:noreply,
         socket
         |> load_relays()
         |> put_flash(:info, "Deleted subscription to #{relay_uri}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  def handle_event("retry", %{"uri" => relay_uri}, socket) do
    # Delete the failed subscription and try again
    case Relay.get_subscription(relay_uri) do
      {:ok, subscription} ->
        Elektrine.Repo.delete(subscription)

        case Relay.subscribe(relay_uri, socket.assigns.current_user.id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> load_relays()
             |> put_flash(:info, "Retry subscription sent to #{relay_uri}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Retry failed: #{inspect(reason)}")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Subscription not found")}
    end
  end

  def handle_event("force_activate", %{"uri" => relay_uri}, socket) do
    case Relay.force_activate(relay_uri) do
      {:ok, _subscription} ->
        {:noreply,
         socket
         |> load_relays()
         |> put_flash(:info, "Relay #{relay_uri} force activated")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Force activation failed: #{inspect(reason)}")}
    end
  end

  def handle_event("force_activate_all", _, socket) do
    {:ok, results} = Relay.force_activate_all_pending()
    activated = Enum.count(results, fn r -> match?({:ok, _}, r) end)

    {:noreply,
     socket
     |> load_relays()
     |> put_flash(:info, "Force activated #{activated} pending subscriptions")}
  end

  def handle_event("resend_follow", %{"uri" => relay_uri}, socket) do
    case Relay.retry_subscription(relay_uri) do
      {:ok, :retried} ->
        {:noreply,
         socket
         |> load_relays()
         |> put_flash(:info, "Follow request resent to #{relay_uri}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to resend: #{inspect(reason)}")}
    end
  end

  def handle_event("refresh", _, socket) do
    {:noreply,
     socket
     |> load_relays()
     |> put_flash(:info, "Refreshed")}
  end

  def handle_event("prev_page", _, socket) do
    {:noreply, socket |> assign(:page, socket.assigns.page - 1) |> load_relays()}
  end

  def handle_event("next_page", _, socket) do
    {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load_relays()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="admin-page">
      <.card class="panel-card" body_class="p-0">
        <:body>
          <div class="flex flex-col gap-6 px-5 py-6 sm:px-8 sm:py-8 xl:flex-row xl:items-end xl:justify-between">
            <div class="max-w-3xl">
              <div class="text-2xs font-semibold uppercase tracking-[0.32em] text-info/80">
                Federation
              </div>

              <h1 class="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">
                ActivityPub Relays
              </h1>

              <p class="mt-3 max-w-2xl text-sm leading-6 text-base-content/70 sm:text-base">
                Subscribe to relays, monitor subscription state, and seed discovery across the broader fediverse.
              </p>

              <div class="mt-5 flex flex-wrap gap-2">
                <div class="surface-muted rounded-box px-3 py-2 text-sm text-base-content/70">
                  Subscriptions: <span class="font-semibold text-base-content">{@stats.total}</span>
                </div>

                <div class="surface-muted rounded-box px-3 py-2 text-sm text-base-content/70">
                  Active: <span class="font-semibold text-base-content">{@stats.active}</span>
                </div>
              </div>
            </div>

            <div class="flex flex-wrap gap-2">
              <.button navigate={~p"/pripyat/federation"} variant="ghost" size="sm">
                <.icon name="hero-globe-alt" class="h-4 w-4" />
                <span class="ml-1 hidden sm:inline">ActivityPub Policies</span>
              </.button>
              <.button navigate={~p"/pripyat/messaging-federation"} variant="ghost" size="sm">
                <.icon name="hero-chat-bubble-left-right" class="h-4 w-4" />
                <span class="ml-1 hidden sm:inline">Chat Federation</span>
              </.button>
              <.button navigate={~p"/pripyat/bluesky-bridge"} variant="ghost" size="sm">
                <.icon name="hero-link" class="h-4 w-4" />
                <span class="ml-1 hidden sm:inline">Bluesky Bridge</span>
              </.button>
              <.button variant="ghost" size="sm" phx-click="refresh" title="Refresh">
                <.icon name="hero-arrow-path" class="h-4 w-4" />
              </.button>
              <.button size="sm" phx-click="show_add_modal">
                <.icon name="hero-plus" class="h-4 w-4" />
                <span class="ml-1">Subscribe</span>
              </.button>
            </div>
          </div>
        </:body>
      </.card>

      <section class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="flex items-center justify-between">
            <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
              Total
            </div>
            <.icon name="hero-signal" class="h-5 w-5 text-primary" />
          </div>

          <div class="mt-3 text-3xl font-semibold text-primary">{@stats.total}</div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="flex items-center justify-between">
            <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
              Active
            </div>
            <.icon name="hero-check-circle" class="h-5 w-5 text-success" />
          </div>

          <div class="mt-3 text-3xl font-semibold text-success">{@stats.active}</div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="flex items-center justify-between">
            <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
              Pending
            </div>
            <.icon name="hero-clock" class="h-5 w-5 text-warning" />
          </div>

          <div class="mt-3 flex items-center gap-2">
            <div class="text-3xl font-semibold text-warning">{@stats.pending}</div>
            <%= if @stats.pending > 0 do %>
              <.button
                variant="warning"
                size="xs"
                phx-click="force_activate_all"
                data-confirm="Force activate all pending relay subscriptions? Use this if relays don't send Accept activities."
                title="Force activate all pending"
              >
                <.icon name="hero-bolt" class="h-3 w-3" />
              </.button>
            <% end %>
          </div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="flex items-center justify-between">
            <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
              Failed
            </div>
            <.icon name="hero-exclamation-triangle" class="h-5 w-5 text-error" />
          </div>

          <div class="mt-3 text-3xl font-semibold text-error">{@stats.error}</div>
        </div>
      </section>

      <div class="rounded-box border border-info/20 bg-info/10 px-4 py-3 text-sm text-base-content/75">
        <div class="flex items-start gap-3">
          <.icon name="hero-information-circle" class="mt-0.5 h-5 w-5 shrink-0 text-info" />
          <div>
            <div class="font-medium text-base-content">What are relays?</div>
            <div class="mt-1">
              Relays are special servers that rebroadcast public content. By subscribing to a relay,
              you'll receive posts from other instances subscribed to the same relay, helping discover
              new content and users across the fediverse.
            </div>
          </div>
        </div>
      </div>

      <.card class="panel-card" body_class="p-0">
        <:body>
          <div class="border-b border-base-content/10 px-5 py-5 sm:px-6">
            <div class="flex items-center justify-between gap-4">
              <div>
                <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
                  Subscriptions
                </div>

                <h2 class="mt-1 text-xl font-semibold tracking-tight">Relay Subscriptions</h2>
              </div>

              <div class="badge badge-ghost badge-sm">{@total_count}</div>
            </div>
          </div>

          <div class="px-5 py-5 sm:px-6">
            <%= if length(@subscriptions) > 0 do %>
              <div class="overflow-x-auto">
                <table class="table w-full">
                  <thead>
                    <tr>
                      <th>Relay</th>
                      <th>Status</th>
                      <th class="hidden sm:table-cell">Software</th>
                      <th class="hidden md:table-cell">Subscribed</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for sub <- @subscriptions do %>
                      <tr>
                        <td>
                          <div class="min-w-0">
                            <div class="font-semibold">{sub.relay_name || "Unknown"}</div>
                            <div class="max-w-xs truncate font-mono text-xs text-base-content/55">
                              {sub.relay_uri}
                            </div>
                          </div>
                        </td>
                        <td>
                          <.relay_status_badge status={sub.status} accepted={sub.accepted} />
                          <%= if sub.error_message do %>
                            <div
                              class="mt-1 max-w-xs truncate text-xs text-error"
                              title={sub.error_message}
                            >
                              {sub.error_message}
                            </div>
                          <% end %>
                        </td>
                        <td class="hidden text-sm text-base-content/60 sm:table-cell">
                          {sub.relay_software || "-"}
                        </td>
                        <td class="hidden text-xs text-base-content/55 md:table-cell">
                          {Calendar.strftime(sub.inserted_at, "%Y-%m-%d %H:%M")}
                        </td>
                        <td>
                          <div class="flex gap-1">
                            <%= if sub.status == "pending" do %>
                              <.button
                                variant="success"
                                size="xs"
                                phx-click="force_activate"
                                phx-value-uri={sub.relay_uri}
                                title="Force activate (skip waiting for Accept)"
                              >
                                <.icon name="hero-bolt" class="h-3 w-3" />
                              </.button>
                              <.button
                                variant="warning"
                                size="xs"
                                phx-click="resend_follow"
                                phx-value-uri={sub.relay_uri}
                                title="Resend Follow request"
                              >
                                <.icon name="hero-arrow-path" class="h-3 w-3" />
                              </.button>
                            <% end %>
                            <%= if sub.status in ["error", "rejected"] do %>
                              <.button
                                variant="warning"
                                size="xs"
                                phx-click="retry"
                                phx-value-uri={sub.relay_uri}
                                title="Retry"
                              >
                                <.icon name="hero-arrow-path" class="h-3 w-3" />
                              </.button>
                            <% end %>
                            <.button
                              variant="ghost"
                              size="xs"
                              class="text-error"
                              phx-click="unsubscribe"
                              phx-value-uri={sub.relay_uri}
                              data-confirm="Unsubscribe from this relay?"
                              title="Unsubscribe (sends Undo Follow)"
                            >
                              <.icon name="hero-trash" class="h-3 w-3" />
                            </.button>
                            <.button
                              variant="error"
                              size="xs"
                              phx-click="force_delete"
                              phx-value-uri={sub.relay_uri}
                              data-confirm="Force delete this subscription without notifying the relay?"
                              title="Force Delete (no notification)"
                            >
                              <.icon name="hero-x-mark" class="h-3 w-3" />
                            </.button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
              <%= if @total_pages > 1 do %>
                <div class="mt-4 flex items-center justify-between gap-3">
                  <span class="text-xs text-base-content/55">Page {@page} of {@total_pages}</span>
                  <div class="join">
                    <.button
                      variant="default"
                      size="sm"
                      class="join-item"
                      phx-click="prev_page"
                      disabled={@page <= 1}
                    >
                      Previous
                    </.button>
                    <.button
                      variant="default"
                      size="sm"
                      class="join-item"
                      phx-click="next_page"
                      disabled={@page >= @total_pages}
                    >
                      Next
                    </.button>
                  </div>
                </div>
              <% end %>
            <% else %>
              <div class="rounded-box border border-dashed border-base-content/15 bg-base-200/45 px-4 py-10 text-center">
                <.icon name="hero-signal" class="mx-auto h-12 w-12 text-base-content/25" />
                <p class="mt-4 text-sm text-base-content/70">No relay subscriptions</p>
                <p class="mt-1 text-sm text-base-content/50">
                  Subscribe to a relay to start receiving federated content
                </p>
                <.button size="sm" class="mt-4" phx-click="show_add_modal">
                  <.icon name="hero-plus" class="mr-1 h-4 w-4" /> Subscribe to a Relay
                </.button>
              </div>
            <% end %>
          </div>
        </:body>
      </.card>

      <.card class="panel-card" body_class="p-0">
        <:body>
          <div class="border-b border-base-content/10 px-5 py-5 sm:px-6">
            <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
              Discovery
            </div>

            <h2 class="mt-1 text-xl font-semibold tracking-tight">Popular Relays</h2>

            <p class="mt-2 text-sm text-base-content/70">
              These are well-known public relays. Only subscribe to relays you trust.
              <a href="https://relaylist.com" target="_blank" class="link link-info">
                View full directory
              </a>
            </p>
          </div>

          <div class="px-5 py-5 sm:px-6">
            <h3 class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Large Relays (1000+ participants)
            </h3>
            <div class="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
              <.relay_suggestion
                name="toot.io"
                url="https://relay.toot.io/actor"
                description="1775 participants - Large general relay"
                participants={1775}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="Intahnet"
                url="https://relay.intahnet.co.uk/actor"
                description="1477 participants - European relay"
                participants={1477}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="Fedinet"
                url="https://relay.fedinet.social/actor"
                description="1166 participants - General relay"
                participants={1166}
                status="down"
                subscription_urls={@subscription_urls}
              />
            </div>
          </div>

          <div class="border-t border-base-content/10 px-5 py-5 sm:px-6">
            <h3 class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Medium Relays (300-1000 participants)
            </h3>
            <div class="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
              <.relay_suggestion
                name="Minecloud"
                url="https://relay.minecloud.ro/actor"
                description="592 participants"
                participants={592}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="Froth Zone"
                url="https://relay.froth.zone/actor"
                description="564 participants"
                participants={564}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="Rel.re"
                url="https://rel.re/actor"
                description="521 participants"
                participants={521}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="Infosec Exchange"
                url="https://relay.infosec.exchange/actor"
                description="427 participants - Security community"
                participants={427}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="Dresden Network"
                url="https://relay.dresden.network/actor"
                description="409 participants - German relay"
                participants={409}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="MyCrowd"
                url="https://relay.mycrowd.ca/actor"
                description="396 participants - Canadian relay"
                participants={396}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="101010.pl"
                url="https://relay.101010.pl/actor"
                description="394 participants - Polish relay"
                participants={394}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="Yukimochi"
                url="https://relay.toot.yukimochi.jp/actor"
                description="313 participants - Japanese relay"
                participants={313}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="Fedibird"
                url="https://relay.fedibird.com/actor"
                description="308 participants - Japanese relay"
                participants={308}
                status="up"
                subscription_urls={@subscription_urls}
              />
            </div>
          </div>

          <div class="border-t border-base-content/10 px-5 py-5 sm:px-6">
            <h3 class="text-2xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
              Smaller Relays (100-300 participants)
            </h3>
            <div class="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <.relay_suggestion
                name="Dico.gg"
                url="https://relay.dico.gg/actor"
                description="218 participants"
                participants={218}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="Relay.Gay"
                url="https://relay.gay/actor"
                description="200 participants - LGBTQ+ community"
                participants={200}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="Mastodon.nu"
                url="https://relay.mastodon.nu/actor"
                description="154 participants - Swedish relay"
                participants={154}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="Uggs.io"
                url="https://relay.uggs.io/actor"
                description="122 participants"
                participants={122}
                status="up"
                subscription_urls={@subscription_urls}
              />
              <.relay_suggestion
                name="Beep.Computer"
                url="https://activityrelay.beep.computer/actor"
                description="110 participants"
                participants={110}
                status="up"
                subscription_urls={@subscription_urls}
              />
            </div>
          </div>
        </:body>
      </.card>

      <%= if @show_add_modal do %>
        <.add_relay_modal adding={@adding} relay_url={@relay_url} />
      <% end %>
    </div>
    """
  end

  defp relay_status_badge(assigns) do
    ~H"""
    <%= case {@status, @accepted} do %>
      <% {"active", true} -> %>
        <span class="badge badge-sm border-0 bg-success/15 text-success">Active</span>
      <% {"pending", _} -> %>
        <span class="badge badge-sm border-0 bg-warning/15 text-warning">Pending</span>
      <% {"rejected", _} -> %>
        <span class="badge badge-sm border-0 bg-error/15 text-error">Rejected</span>
      <% {"error", _} -> %>
        <span class="badge badge-sm border-0 bg-error/15 text-error">Error</span>
      <% _ -> %>
        <span class="badge badge-sm border-0 bg-base-200 text-base-content/60">{@status}</span>
    <% end %>
    """
  end

  defp relay_suggestion(assigns) do
    assigns =
      assigns
      |> assign(:already_subscribed, MapSet.member?(assigns.subscription_urls, assigns.url))
      |> assign_new(:participants, fn -> nil end)
      |> assign_new(:status, fn -> "up" end)

    ~H"""
    <div class={[
      "rounded-box border border-base-content/10 bg-base-200/45 px-4 py-4",
      @status == "down" && "opacity-60"
    ]}>
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <h3 class="truncate text-sm font-semibold">{@name}</h3>
            <%= if @status == "up" do %>
              <span class="badge badge-xs border-0 bg-success/15 text-success">online</span>
            <% else %>
              <span class="badge badge-xs border-0 bg-error/15 text-error">offline</span>
            <% end %>
          </div>
          <p class="mt-1 text-xs text-base-content/60">{@description}</p>
        </div>
        <%= if @participants do %>
          <div class="text-right">
            <div class="text-sm font-semibold">{format_number(@participants)}</div>
            <div class="text-3xs uppercase tracking-[0.14em] text-base-content/40">
              instances
            </div>
          </div>
        <% end %>
      </div>
      <div class="mt-3 flex items-center justify-between gap-2">
        <div class="max-w-[150px] truncate font-mono text-3xs text-base-content/40">{@url}</div>
        <%= if @already_subscribed do %>
          <span class="badge badge-xs border-0 bg-success/15 text-success">Subscribed</span>
        <% else %>
          <%= if @status == "up" do %>
            <.button
              size="xs"
              phx-click="subscribe"
              phx-value-relay_url={@url}
            >
              Subscribe
            </.button>
          <% else %>
            <span class="badge badge-xs border-0 bg-base-200 text-base-content/60">Offline</span>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_number(num) when num >= 1000 do
    "#{Float.round(num / 1000, 1)}k"
  end

  defp format_number(num), do: to_string(num)

  defp add_relay_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box modal-surface">
        <div class="flex items-center gap-3">
          <div class="flex h-10 w-10 items-center justify-center rounded-full bg-primary/10 text-primary">
            <.icon name="hero-plus" class="h-5 w-5" />
          </div>
          <h3 class="text-lg font-semibold tracking-tight">Subscribe to Relay</h3>
        </div>

        <form phx-submit="subscribe" class="mt-5">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Relay Actor URL</span>
            </label>
            <input
              type="url"
              name="relay_url"
              value={@relay_url}
              phx-keyup="update_relay_url"
              placeholder="https://relay.example.com/actor"
              class="input input-bordered w-full font-mono"
              required
              autofocus
              disabled={@adding}
            />
            <label class="label">
              <span class="label-text-alt text-base-content/60">
                Enter the relay's actor URL (usually ending in /actor)
              </span>
            </label>
          </div>

          <div class="mt-4 rounded-box border border-warning/20 bg-warning/10 px-4 py-3 text-sm text-base-content/75">
            <div class="flex items-start gap-3">
              <.icon
                name="hero-exclamation-triangle"
                class="mt-0.5 h-4 w-4 shrink-0 text-warning"
              />
              <span>
                Only subscribe to relays you trust. Relays can significantly increase the amount of content your instance receives.
              </span>
            </div>
          </div>

          <div class="modal-action">
            <.button type="button" variant="default" phx-click="close_modal" disabled={@adding}>
              Cancel
            </.button>
            <.button type="submit" disabled={@adding}>
              <%= if @adding do %>
                <.spinner size="sm" /> Subscribing...
              <% else %>
                Subscribe
              <% end %>
            </.button>
          </div>
        </form>
      </div>
      <form method="dialog" class="modal-backdrop" phx-click="close_modal">
        <button>close</button>
      </form>
    </div>
    """
  end
end
