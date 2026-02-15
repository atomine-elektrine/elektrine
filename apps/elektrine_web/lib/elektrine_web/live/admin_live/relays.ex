defmodule ElektrineWeb.AdminLive.Relays do
  @moduledoc """
  Admin LiveView for managing ActivityPub relay subscriptions.
  """
  use ElektrineWeb, :live_view

  alias Elektrine.ActivityPub.Relay
  alias Elektrine.ActivityPub.RelaySubscription

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_user] && socket.assigns.current_user.is_admin do
      {:ok,
       socket
       |> assign(:page_title, "Relay Management")
       |> assign(:show_add_modal, false)
       |> assign(:relay_url, "")
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
    subscriptions = Relay.list_subscriptions()

    stats = %{
      total: length(subscriptions),
      active: Enum.count(subscriptions, &RelaySubscription.active?/1),
      pending: Enum.count(subscriptions, fn s -> s.status == "pending" end),
      error: Enum.count(subscriptions, fn s -> s.status in ["error", "rejected"] end)
    }

    socket
    |> assign(:subscriptions, subscriptions)
    |> assign(:stats, stats)
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

    if relay_url == "" do
      {:noreply, put_flash(socket, :error, "Please enter a relay URL")}
    else
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <!-- Header -->
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 mb-6">
        <div>
          <h1 class="text-xl sm:text-2xl font-bold">Relay Management</h1>
          <p class="text-sm opacity-70 mt-1">
            Subscribe to ActivityPub relays to discover content from other instances
          </p>
        </div>
        <div class="flex gap-2">
          <.link navigate={~p"/pripyat/federation"} class="btn btn-sm btn-ghost">
            <.icon name="hero-globe-alt" class="w-4 h-4" />
            <span class="hidden sm:inline ml-1">Federation</span>
          </.link>
          <button phx-click="show_add_modal" class="btn btn-sm btn-primary">
            <.icon name="hero-plus" class="w-4 h-4" />
            <span class="ml-1">Subscribe</span>
          </button>
          <button phx-click="refresh" class="btn btn-sm btn-ghost">
            <.icon name="hero-arrow-path" class="w-4 h-4" />
          </button>
        </div>
      </div>
      
    <!-- Stats -->
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 mb-6">
        <div class="card glass-card shadow">
          <div class="card-body p-4">
            <div class="flex items-center gap-2">
              <.icon name="hero-signal" class="w-4 h-4 text-primary opacity-70" />
              <span class="text-xs opacity-70">Total</span>
            </div>
            <div class="text-xl font-bold">{@stats.total}</div>
          </div>
        </div>
        <div class="card glass-card shadow">
          <div class="card-body p-4">
            <div class="flex items-center gap-2">
              <.icon name="hero-check-circle" class="w-4 h-4 text-success opacity-70" />
              <span class="text-xs opacity-70">Active</span>
            </div>
            <div class="text-xl font-bold text-success">{@stats.active}</div>
          </div>
        </div>
        <div class="card glass-card shadow">
          <div class="card-body p-4">
            <div class="flex items-center gap-2">
              <.icon name="hero-clock" class="w-4 h-4 text-warning opacity-70" />
              <span class="text-xs opacity-70">Pending</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="text-xl font-bold text-warning">{@stats.pending}</div>
              <%= if @stats.pending > 0 do %>
                <button
                  phx-click="force_activate_all"
                  data-confirm="Force activate all pending relay subscriptions? Use this if relays don't send Accept activities."
                  class="btn btn-xs btn-warning"
                  title="Force activate all pending"
                >
                  <.icon name="hero-bolt" class="w-3 h-3" />
                </button>
              <% end %>
            </div>
          </div>
        </div>
        <div class="card glass-card shadow">
          <div class="card-body p-4">
            <div class="flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-error opacity-70" />
              <span class="text-xs opacity-70">Failed</span>
            </div>
            <div class="text-xl font-bold text-error">{@stats.error}</div>
          </div>
        </div>
      </div>
      
    <!-- Info alert -->
      <div class="alert alert-info mb-6">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <div>
          <div class="font-medium">What are relays?</div>
          <div class="text-sm opacity-80">
            Relays are special servers that rebroadcast public content. By subscribing to a relay,
            you'll receive posts from other instances subscribed to the same relay, helping discover
            new content and users across the fediverse.
          </div>
        </div>
      </div>
      
    <!-- Subscriptions Table -->
      <div class="card glass-card shadow">
        <div class="card-body p-4 sm:p-6">
          <h2 class="card-title text-base sm:text-lg mb-4">
            <.icon name="hero-signal" class="w-5 h-5" /> Relay Subscriptions
          </h2>

          <%= if length(@subscriptions) > 0 do %>
            <div class="overflow-x-auto">
              <table class="table table-zebra">
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
                        <div>
                          <div class="font-medium">{sub.relay_name || "Unknown"}</div>
                          <div class="text-xs opacity-70 font-mono truncate max-w-xs">
                            {sub.relay_uri}
                          </div>
                        </div>
                      </td>
                      <td>
                        <.relay_status_badge status={sub.status} accepted={sub.accepted} />
                        <%= if sub.error_message do %>
                          <div
                            class="text-xs text-error mt-1 max-w-xs truncate"
                            title={sub.error_message}
                          >
                            {sub.error_message}
                          </div>
                        <% end %>
                      </td>
                      <td class="hidden sm:table-cell text-sm opacity-70">
                        {sub.relay_software || "-"}
                      </td>
                      <td class="hidden md:table-cell text-xs opacity-70">
                        {Calendar.strftime(sub.inserted_at, "%Y-%m-%d %H:%M")}
                      </td>
                      <td>
                        <div class="flex gap-1">
                          <%= if sub.status == "pending" do %>
                            <button
                              phx-click="force_activate"
                              phx-value-uri={sub.relay_uri}
                              class="btn btn-xs btn-success"
                              title="Force activate (skip waiting for Accept)"
                            >
                              <.icon name="hero-bolt" class="w-3 h-3" />
                            </button>
                            <button
                              phx-click="resend_follow"
                              phx-value-uri={sub.relay_uri}
                              class="btn btn-xs btn-warning"
                              title="Resend Follow request"
                            >
                              <.icon name="hero-arrow-path" class="w-3 h-3" />
                            </button>
                          <% end %>
                          <%= if sub.status in ["error", "rejected"] do %>
                            <button
                              phx-click="retry"
                              phx-value-uri={sub.relay_uri}
                              class="btn btn-xs btn-warning"
                              title="Retry"
                            >
                              <.icon name="hero-arrow-path" class="w-3 h-3" />
                            </button>
                          <% end %>
                          <button
                            phx-click="unsubscribe"
                            phx-value-uri={sub.relay_uri}
                            data-confirm="Unsubscribe from this relay?"
                            class="btn btn-xs btn-error btn-ghost"
                            title="Unsubscribe (sends Undo Follow)"
                          >
                            <.icon name="hero-trash" class="w-3 h-3" />
                          </button>
                          <button
                            phx-click="force_delete"
                            phx-value-uri={sub.relay_uri}
                            data-confirm="Force delete this subscription without notifying the relay?"
                            class="btn btn-xs btn-error"
                            title="Force Delete (no notification)"
                          >
                            <.icon name="hero-x-mark" class="w-3 h-3" />
                          </button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% else %>
            <div class="text-center py-12">
              <.icon name="hero-signal" class="w-12 h-12 mx-auto opacity-30 mb-4" />
              <p class="opacity-70">No relay subscriptions</p>
              <p class="text-sm opacity-50 mt-1">
                Subscribe to a relay to start receiving federated content
              </p>
              <button phx-click="show_add_modal" class="btn btn-primary btn-sm mt-4">
                <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Subscribe to a Relay
              </button>
            </div>
          <% end %>
        </div>
      </div>
      
    <!-- Popular Relays -->
      <div class="card glass-card shadow mt-6">
        <div class="card-body p-4 sm:p-6">
          <h2 class="card-title text-base sm:text-lg mb-2">
            <.icon name="hero-star" class="w-5 h-5" /> Popular Relays
          </h2>
          <p class="text-sm opacity-70 mb-4">
            These are well-known public relays. Only subscribe to relays you trust.
            <a href="https://relaylist.com" target="_blank" class="link link-primary">
              View full directory
            </a>
          </p>
          
    <!-- Large Relays -->
          <h3 class="text-sm font-semibold opacity-70 mb-2 mt-4">
            Large Relays (1000+ participants)
          </h3>
          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 mb-4">
            <.relay_suggestion
              name="toot.io"
              url="https://relay.toot.io/actor"
              description="1775 participants - Large general relay"
              participants={1775}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="Intahnet"
              url="https://relay.intahnet.co.uk/actor"
              description="1477 participants - European relay"
              participants={1477}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="Fedinet"
              url="https://relay.fedinet.social/actor"
              description="1166 participants - General relay"
              participants={1166}
              status="down"
              subscriptions={@subscriptions}
            />
          </div>
          
    <!-- Medium Relays -->
          <h3 class="text-sm font-semibold opacity-70 mb-2">Medium Relays (300-1000 participants)</h3>
          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 mb-4">
            <.relay_suggestion
              name="Minecloud"
              url="https://relay.minecloud.ro/actor"
              description="592 participants"
              participants={592}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="Froth Zone"
              url="https://relay.froth.zone/actor"
              description="564 participants"
              participants={564}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="Rel.re"
              url="https://rel.re/actor"
              description="521 participants"
              participants={521}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="Infosec Exchange"
              url="https://relay.infosec.exchange/actor"
              description="427 participants - Security community"
              participants={427}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="Dresden Network"
              url="https://relay.dresden.network/actor"
              description="409 participants - German relay"
              participants={409}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="MyCrowd"
              url="https://relay.mycrowd.ca/actor"
              description="396 participants - Canadian relay"
              participants={396}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="101010.pl"
              url="https://relay.101010.pl/actor"
              description="394 participants - Polish relay"
              participants={394}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="Yukimochi"
              url="https://relay.toot.yukimochi.jp/actor"
              description="313 participants - Japanese relay"
              participants={313}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="Fedibird"
              url="https://relay.fedibird.com/actor"
              description="308 participants - Japanese relay"
              participants={308}
              status="up"
              subscriptions={@subscriptions}
            />
          </div>
          
    <!-- Smaller Relays -->
          <h3 class="text-sm font-semibold opacity-70 mb-2">Smaller Relays (100-300 participants)</h3>
          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <.relay_suggestion
              name="Dico.gg"
              url="https://relay.dico.gg/actor"
              description="218 participants"
              participants={218}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="Relay.Gay"
              url="https://relay.gay/actor"
              description="200 participants - LGBTQ+ community"
              participants={200}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="Mastodon.nu"
              url="https://relay.mastodon.nu/actor"
              description="154 participants - Swedish relay"
              participants={154}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="Uggs.io"
              url="https://relay.uggs.io/actor"
              description="122 participants"
              participants={122}
              status="up"
              subscriptions={@subscriptions}
            />
            <.relay_suggestion
              name="Beep.Computer"
              url="https://activityrelay.beep.computer/actor"
              description="110 participants"
              participants={110}
              status="up"
              subscriptions={@subscriptions}
            />
          </div>
        </div>
      </div>
      
    <!-- Add Modal -->
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
        <span class="badge badge-success badge-sm">Active</span>
      <% {"pending", _} -> %>
        <span class="badge badge-warning badge-sm">Pending</span>
      <% {"rejected", _} -> %>
        <span class="badge badge-error badge-sm">Rejected</span>
      <% {"error", _} -> %>
        <span class="badge badge-error badge-sm">Error</span>
      <% _ -> %>
        <span class="badge badge-neutral badge-sm">{@status}</span>
    <% end %>
    """
  end

  defp relay_suggestion(assigns) do
    already_subscribed =
      Enum.any?(assigns.subscriptions, fn s -> s.relay_uri == assigns.url end)

    assigns =
      assigns
      |> assign(:already_subscribed, already_subscribed)
      |> assign_new(:participants, fn -> nil end)
      |> assign_new(:status, fn -> "up" end)

    ~H"""
    <div class={["card bg-base-200", @status == "down" && "opacity-60"]}>
      <div class="card-body p-3">
        <div class="flex items-start justify-between gap-2">
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2">
              <h3 class="font-medium text-sm truncate">{@name}</h3>
              <%= if @status == "up" do %>
                <span class="badge badge-xs badge-success">online</span>
              <% else %>
                <span class="badge badge-xs badge-error">offline</span>
              <% end %>
            </div>
            <p class="text-xs opacity-70 mt-0.5">{@description}</p>
          </div>
          <%= if @participants do %>
            <div class="text-right">
              <div class="text-sm font-bold">{format_number(@participants)}</div>
              <div class="text-[10px] opacity-50">instances</div>
            </div>
          <% end %>
        </div>
        <div class="flex items-center justify-between mt-2">
          <div class="text-[10px] font-mono opacity-40 truncate max-w-[150px]">{@url}</div>
          <%= if @already_subscribed do %>
            <span class="badge badge-xs badge-success">Subscribed</span>
          <% else %>
            <%= if @status == "up" do %>
              <button
                phx-click="subscribe"
                phx-value-relay_url={@url}
                class="btn btn-xs btn-primary"
              >
                Subscribe
              </button>
            <% else %>
              <span class="badge badge-xs badge-neutral">Offline</span>
            <% end %>
          <% end %>
        </div>
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
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">
          <.icon name="hero-plus" class="w-5 h-5 inline mr-2" /> Subscribe to Relay
        </h3>

        <form phx-submit="subscribe">
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
              class="input input-bordered font-mono"
              required
              autofocus
              disabled={@adding}
            />
            <label class="label">
              <span class="label-text-alt opacity-70">
                Enter the relay's actor URL (usually ending in /actor)
              </span>
            </label>
          </div>

          <div class="alert alert-warning text-sm mt-4">
            <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
            <span>
              Only subscribe to relays you trust. Relays can significantly increase the amount of content your instance receives.
            </span>
          </div>

          <div class="modal-action">
            <button type="button" phx-click="close_modal" class="btn" disabled={@adding}>
              Cancel
            </button>
            <button type="submit" class="btn btn-primary" disabled={@adding}>
              <%= if @adding do %>
                <span class="loading loading-spinner loading-sm"></span> Subscribing...
              <% else %>
                Subscribe
              <% end %>
            </button>
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
