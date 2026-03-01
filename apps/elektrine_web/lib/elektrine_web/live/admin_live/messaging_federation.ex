defmodule ElektrineWeb.AdminLive.MessagingFederation do
  use ElektrineWeb, :live_view

  alias Elektrine.Messaging.Federation

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_user] && socket.assigns.current_user.is_admin do
      {:ok,
       socket
       |> assign(:page_title, "Arblarg Messaging Federation")
       |> assign(:search_query, "")
       |> assign(:page, 1)
       |> assign(:per_page, 50)
       |> assign(:new_domain, "")
       |> assign(:new_reason, "")
       |> load_controls()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> assign(:page, 1) |> load_controls()}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, socket |> assign(:search_query, "") |> assign(:page, 1) |> load_controls()}
  end

  def handle_event("prev_page", _params, socket) do
    {:noreply, socket |> assign(:page, socket.assigns.page - 1) |> load_controls()}
  end

  def handle_event("next_page", _params, socket) do
    {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load_controls()}
  end

  def handle_event("update_new_domain", %{"value" => value}, socket) do
    {:noreply, assign(socket, :new_domain, value)}
  end

  def handle_event("update_new_domain", %{"domain" => value}, socket) do
    {:noreply, assign(socket, :new_domain, value)}
  end

  def handle_event("update_new_reason", %{"value" => value}, socket) do
    {:noreply, assign(socket, :new_reason, value)}
  end

  def handle_event("update_new_reason", %{"reason" => value}, socket) do
    {:noreply, assign(socket, :new_reason, value)}
  end

  def handle_event("block_domain", params, socket) do
    domain = Map.get(params, "domain", socket.assigns.new_domain)
    reason = Map.get(params, "reason", socket.assigns.new_reason)

    case Federation.block_peer_domain(
           domain,
           reason,
           socket.assigns.current_user.id
         ) do
      {:ok, _policy} ->
        {:noreply,
         socket
         |> assign(:new_domain, "")
         |> assign(:new_reason, "")
         |> load_controls()
         |> put_flash(:info, "Domain blocked for messaging federation")}

      {:error, :invalid_domain} ->
        {:noreply, put_flash(socket, :error, "Invalid domain")}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Failed to block domain: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("unblock_domain", %{"domain" => domain}, socket) do
    case Federation.unblock_peer_domain(domain, socket.assigns.current_user.id) do
      {:ok, _policy} ->
        {:noreply,
         socket
         |> load_controls()
         |> put_flash(:info, "Domain unblocked for messaging federation")}

      {:error, :invalid_domain} ->
        {:noreply, put_flash(socket, :error, "Invalid domain")}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Failed to unblock domain: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event(
        "set_direction",
        %{"domain" => domain, "direction" => direction, "mode" => mode},
        socket
      ) do
    attrs =
      case {direction, mode_to_override(mode)} do
        {"incoming", {:ok, override}} -> %{allow_incoming: override}
        {"outgoing", {:ok, override}} -> %{allow_outgoing: override}
        _ -> %{}
      end

    if attrs == %{} do
      {:noreply, put_flash(socket, :error, "Invalid direction override")}
    else
      case Federation.upsert_peer_policy(domain, attrs, socket.assigns.current_user.id) do
        {:ok, _policy} ->
          {:noreply,
           socket
           |> load_controls()
           |> put_flash(:info, "Directional policy updated")}

        {:error, :invalid_domain} ->
          {:noreply, put_flash(socket, :error, "Invalid domain")}

        {:error, changeset} ->
          {:noreply,
           put_flash(socket, :error, "Failed to update policy: #{inspect(changeset.errors)}")}
      end
    end
  end

  def handle_event("clear_policy", %{"domain" => domain}, socket) do
    case Federation.clear_peer_policy(domain) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_controls()
         |> put_flash(:info, "Runtime override cleared")}

      {:error, :invalid_domain} ->
        {:noreply, put_flash(socket, :error, "Invalid domain")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to clear runtime override")}
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_controls() |> put_flash(:info, "Refreshed")}
  end

  defp load_controls(socket) do
    controls = Federation.list_peer_controls()
    query = socket.assigns[:search_query] || ""
    page = socket.assigns[:page] || 1
    per_page = socket.assigns[:per_page] || 50

    filtered_controls =
      if query == "" do
        controls
      else
        needle = String.downcase(String.trim(query))
        Enum.filter(controls, &String.contains?(String.downcase(&1.domain), needle))
      end

    total_count = length(filtered_controls)
    total_pages = total_pages(total_count, per_page)
    safe_page = clamp_page(page, total_pages)
    offset = (safe_page - 1) * per_page

    paged_controls =
      filtered_controls
      |> Enum.drop(offset)
      |> Enum.take(per_page)

    socket
    |> assign(:all_peer_controls, controls)
    |> assign(:peer_controls, paged_controls)
    |> assign(:filtered_peer_total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:page, safe_page)
    |> assign(:blocked_peer_count, Enum.count(controls, & &1.blocked))
    |> assign(:incoming_denied_count, Enum.count(controls, &(not &1.effective_allow_incoming)))
    |> assign(:outgoing_denied_count, Enum.count(controls, &(not &1.effective_allow_outgoing)))
  end

  defp mode_to_override("allow"), do: {:ok, true}
  defp mode_to_override("deny"), do: {:ok, false}
  defp mode_to_override("inherit"), do: {:ok, nil}
  defp mode_to_override(_), do: :error

  defp total_pages(total_count, per_page) when total_count > 0 and per_page > 0 do
    div(total_count + per_page - 1, per_page)
  end

  defp total_pages(_, _), do: 1

  defp clamp_page(page, _total_pages) when page < 1, do: 1
  defp clamp_page(page, total_pages) when page > total_pages, do: total_pages
  defp clamp_page(page, _total_pages), do: page

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-6">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 class="text-xl sm:text-2xl font-bold">Arblarg Messaging Federation</h1>
          <p class="text-sm opacity-70 mt-1">
            Controls signed Arblarg chat federation between servers (DMs, channels, reactions, read
            receipts). This is separate from ActivityPub moderation and Bluesky bridging.
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <.link navigate={~p"/pripyat/federation"} class="btn btn-sm btn-ghost">
            <.icon name="hero-globe-alt" class="w-4 h-4" />
            <span class="ml-1">ActivityPub Policies</span>
          </.link>
          <.link navigate={~p"/pripyat/bluesky-bridge"} class="btn btn-sm btn-ghost">
            <.icon name="hero-link" class="w-4 h-4" />
            <span class="ml-1">Bluesky Bridge</span>
          </.link>
          <button phx-click="refresh" class="btn btn-sm btn-ghost">
            <.icon name="hero-arrow-path" class="w-4 h-4" />
            <span class="ml-1">Refresh</span>
          </button>
        </div>
      </div>

      <div class="alert bg-base-200 border border-base-300">
        <.icon name="hero-information-circle" class="w-5 h-5 text-info" />
        <span class="text-sm">
          Incoming controls whether this server accepts Arblarg events from a peer. Outgoing controls
          whether this server sends local events to that peer.
        </span>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <div class="card bg-base-200 shadow">
          <div class="card-body p-4">
            <div class="text-xs opacity-70">Blocked Peers</div>
            <div class="text-2xl font-semibold text-error">{@blocked_peer_count}</div>
          </div>
        </div>
        <div class="card bg-base-200 shadow">
          <div class="card-body p-4">
            <div class="text-xs opacity-70">Incoming Denied</div>
            <div class="text-2xl font-semibold">{@incoming_denied_count}</div>
          </div>
        </div>
        <div class="card bg-base-200 shadow">
          <div class="card-body p-4">
            <div class="text-xs opacity-70">Outgoing Denied</div>
            <div class="text-2xl font-semibold">{@outgoing_denied_count}</div>
          </div>
        </div>
      </div>

      <div class="card glass-card shadow">
        <div class="card-body p-4 sm:p-6">
          <h2 class="card-title text-base sm:text-lg mb-4">
            <.icon name="hero-no-symbol" class="w-5 h-5" /> Block Peer for Arblarg Messaging
          </h2>
          <p class="text-sm opacity-70 mb-4">
            Use this when a remote server should not exchange Arblarg chat events with this instance.
          </p>

          <form phx-submit="block_domain" class="grid grid-cols-1 md:grid-cols-6 gap-3">
            <input
              type="text"
              name="domain"
              value={@new_domain}
              placeholder="chat-peer.example"
              class="input input-bordered md:col-span-2 font-mono"
              phx-input="update_new_domain"
              required
            />
            <input
              type="text"
              name="reason"
              value={@new_reason}
              placeholder="optional reason"
              class="input input-bordered md:col-span-3"
              phx-input="update_new_reason"
            />
            <button type="submit" class="btn btn-error md:col-span-1">
              <.icon name="hero-no-symbol" class="w-4 h-4" /> Block
            </button>
          </form>
        </div>
      </div>

      <div class="card glass-card shadow">
        <div class="card-body p-4 sm:p-6">
          <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3 mb-4">
            <h2 class="card-title text-base sm:text-lg">
              <.icon name="hero-server-stack" class="w-5 h-5" /> Arblarg Peer Policy Matrix
              <span class="badge badge-neutral">{@filtered_peer_total_count}</span>
            </h2>

            <form phx-submit="search" class="flex gap-2">
              <input
                type="text"
                name="query"
                value={@search_query}
                placeholder="Search domain..."
                class="input input-bordered input-sm"
              />
              <button type="submit" class="btn btn-sm btn-primary">
                <.icon name="hero-magnifying-glass" class="w-4 h-4" />
              </button>
              <%= if @search_query != "" do %>
                <button type="button" phx-click="clear_search" class="btn btn-sm btn-ghost">
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              <% end %>
            </form>
          </div>

          <%= if @peer_controls == [] do %>
            <div class="text-center py-10 opacity-70">No peers match the current filter.</div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-zebra table-sm">
                <thead>
                  <tr>
                    <th>Domain</th>
                    <th>Status</th>
                    <th>Incoming Arblarg</th>
                    <th>Outgoing Arblarg</th>
                    <th class="hidden md:table-cell">Reason / Note</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for peer <- @peer_controls do %>
                    <tr>
                      <td>
                        <div class="font-mono text-xs sm:text-sm">{peer.domain}</div>
                        <div class="text-xs opacity-60">
                          <%= if peer.configured do %>
                            configured policy
                          <% else %>
                            runtime override only
                          <% end %>
                        </div>
                      </td>
                      <td>
                        <%= if peer.blocked do %>
                          <span class="badge badge-error badge-sm">Blocked</span>
                        <% else %>
                          <span class="badge badge-success badge-sm">Active</span>
                        <% end %>
                      </td>
                      <td>
                        <div class="flex flex-col gap-1">
                          <span class={[
                            "badge badge-xs",
                            if(peer.effective_allow_incoming,
                              do: "badge-success",
                              else: "badge-neutral"
                            )
                          ]}>
                            {if peer.effective_allow_incoming, do: "allowed", else: "denied"}
                          </span>
                          <select
                            class="select select-bordered select-xs"
                            name="mode"
                            phx-change="set_direction"
                            phx-value-domain={peer.domain}
                            phx-value-direction="incoming"
                          >
                            <option value="inherit" selected={is_nil(peer.allow_incoming_override)}>
                              inherit default
                            </option>
                            <option value="allow" selected={peer.allow_incoming_override == true}>
                              allow
                            </option>
                            <option value="deny" selected={peer.allow_incoming_override == false}>
                              deny
                            </option>
                          </select>
                        </div>
                      </td>
                      <td>
                        <div class="flex flex-col gap-1">
                          <span class={[
                            "badge badge-xs",
                            if(peer.effective_allow_outgoing,
                              do: "badge-success",
                              else: "badge-neutral"
                            )
                          ]}>
                            {if peer.effective_allow_outgoing, do: "allowed", else: "denied"}
                          </span>
                          <select
                            class="select select-bordered select-xs"
                            name="mode"
                            phx-change="set_direction"
                            phx-value-domain={peer.domain}
                            phx-value-direction="outgoing"
                          >
                            <option value="inherit" selected={is_nil(peer.allow_outgoing_override)}>
                              inherit default
                            </option>
                            <option value="allow" selected={peer.allow_outgoing_override == true}>
                              allow
                            </option>
                            <option value="deny" selected={peer.allow_outgoing_override == false}>
                              deny
                            </option>
                          </select>
                        </div>
                      </td>
                      <td class="hidden md:table-cell text-xs opacity-70 max-w-xs truncate">
                        {peer.reason || "-"}
                      </td>
                      <td>
                        <div class="flex items-center gap-1">
                          <%= if peer.blocked do %>
                            <button
                              phx-click="unblock_domain"
                              phx-value-domain={peer.domain}
                              class="btn btn-xs btn-success btn-ghost"
                              title="Unblock peer"
                            >
                              <.icon name="hero-check" class="w-3 h-3" />
                              <span class="hidden lg:inline">Unblock</span>
                            </button>
                          <% else %>
                            <button
                              phx-click="block_domain"
                              phx-value-domain={peer.domain}
                              phx-value-reason={peer.reason || ""}
                              class="btn btn-xs btn-error btn-ghost"
                              title="Block peer"
                            >
                              <.icon name="hero-no-symbol" class="w-3 h-3" />
                              <span class="hidden lg:inline">Block</span>
                            </button>
                          <% end %>
                          <button
                            phx-click="clear_policy"
                            phx-value-domain={peer.domain}
                            class="btn btn-xs btn-ghost"
                            title="Reset runtime overrides to configured defaults"
                          >
                            <.icon name="hero-arrow-path-rounded-square" class="w-3 h-3" />
                            <span class="hidden lg:inline">Reset</span>
                          </button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
            <%= if @total_pages > 1 do %>
              <div class="flex items-center justify-between mt-4">
                <span class="text-xs opacity-70">
                  Page {@page} of {@total_pages}
                </span>
                <div class="join">
                  <button phx-click="prev_page" class="btn btn-sm join-item" disabled={@page <= 1}>
                    Previous
                  </button>
                  <button
                    phx-click="next_page"
                    class="btn btn-sm join-item"
                    disabled={@page >= @total_pages}
                  >
                    Next
                  </button>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
