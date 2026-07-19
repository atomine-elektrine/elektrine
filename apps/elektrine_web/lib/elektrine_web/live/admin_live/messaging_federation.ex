defmodule ElektrineWeb.AdminLive.MessagingFederation do
  use ElektrineWeb, :live_view

  alias Elektrine.Messaging.Federation

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_user] && socket.assigns.current_user.is_admin do
      {:ok,
       socket
       |> assign(:page_title, "Chat Federation")
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

  def handle_event("refresh_discovery", %{"domain" => domain}, socket) do
    case Federation.refresh_peer_discovery(domain) do
      {:ok, _peer} ->
        {:noreply,
         socket
         |> load_controls()
         |> put_flash(:info, "Peer discovery refreshed")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Discovery refresh failed: #{inspect(reason)}")}
    end
  end

  defp load_controls(socket) do
    query = socket.assigns[:search_query] || ""
    page = socket.assigns[:page] || 1
    per_page = socket.assigns[:per_page] || 50
    result = Federation.paginate_peer_controls(query, page, per_page)

    socket
    |> assign(:peer_controls, result.entries)
    |> assign(:filtered_peer_total_count, result.total_count)
    |> assign(:total_pages, result.total_pages)
    |> assign(:page, result.page)
    |> assign(:blocked_peer_count, result.stats.blocked)
    |> assign(:incoming_denied_count, result.stats.incoming_denied)
    |> assign(:outgoing_denied_count, result.stats.outgoing_denied)
  end

  defp mode_to_override("allow"), do: {:ok, true}
  defp mode_to_override("deny"), do: {:ok, false}
  defp mode_to_override("inherit"), do: {:ok, nil}
  defp mode_to_override(_), do: :error

  @impl true
  def render(assigns) do
    ~H"""
    <div class="admin-page">
      <.card class="panel-card" body_class="p-0">
        <:body>
          <div class="flex flex-col gap-6 px-5 py-6 sm:px-8 sm:py-8 xl:flex-row xl:items-end xl:justify-between">
            <div class="max-w-3xl">
              <div class="text-2xs font-semibold uppercase tracking-[0.32em] text-primary/80">
                Federation
              </div>

              <h1 class="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Chat Federation</h1>

              <p class="mt-3 max-w-2xl text-sm leading-6 text-base-content/70 sm:text-base">
                Manage signed chat federation, including configured peers, discovery metadata, and
                per-direction runtime overrides. Powered by Arblarg.
              </p>

              <div class="mt-5 flex flex-wrap gap-2">
                <div class="surface-muted rounded-box px-3 py-2 text-sm text-base-content/70">
                  Peers:
                  <span class="font-semibold text-base-content">{@filtered_peer_total_count}</span>
                </div>

                <div class="surface-muted rounded-box px-3 py-2 text-sm text-base-content/70">
                  Blocked: <span class="font-semibold text-base-content">{@blocked_peer_count}</span>
                </div>
              </div>
            </div>

            <div class="flex flex-wrap gap-2">
              <.button navigate={~p"/pripyat/federation"} variant="ghost" size="sm">
                <.icon name="hero-globe-alt" class="w-4 h-4" />
                <span class="ml-1">ActivityPub Policies</span>
              </.button>
              <.button navigate={~p"/pripyat/bluesky-bridge"} variant="ghost" size="sm">
                <.icon name="hero-link" class="w-4 h-4" />
                <span class="ml-1">Bluesky Bridge</span>
              </.button>
              <.button variant="ghost" size="sm" phx-click="refresh">
                <.icon name="hero-arrow-path" class="w-4 h-4" />
                <span class="ml-1">Refresh</span>
              </.button>
            </div>
          </div>
        </:body>
      </.card>

      <div class="rounded-box border border-info/20 bg-info/10 px-4 py-3 text-sm text-base-content/75">
        <div class="flex items-start gap-3">
          <.icon name="hero-information-circle" class="mt-0.5 h-5 w-5 shrink-0 text-info" />
          <span>
            Incoming controls whether this server accepts chat events from a peer. Outgoing controls
            whether this server sends local events to that peer. Discovered peers come from open
            federation bootstrap and keep their own trust/key-rotation metadata.
          </span>
        </div>
      </div>

      <section class="grid gap-3 sm:grid-cols-3">
        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Blocked Peers
          </div>

          <div class="mt-2 text-3xl font-semibold text-error">{@blocked_peer_count}</div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Incoming Denied
          </div>

          <div class="mt-2 text-3xl font-semibold text-warning">{@incoming_denied_count}</div>
        </div>

        <div class="surface-muted rounded-box px-4 py-4 shadow-sm">
          <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
            Outgoing Denied
          </div>

          <div class="mt-2 text-3xl font-semibold text-warning">{@outgoing_denied_count}</div>
        </div>
      </section>

      <.card class="panel-card" body_class="p-0">
        <:body>
          <div class="border-b border-base-content/10 px-5 py-5 sm:px-6">
            <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
              Moderation
            </div>

            <h2 class="mt-1 text-xl font-semibold tracking-tight">
              Block Peer for Chat Federation
            </h2>

            <p class="mt-2 text-sm text-base-content/70">
              Use this when a remote server should not exchange chat events with this instance.
            </p>
          </div>

          <div class="px-5 py-5 sm:px-6">
            <form phx-submit="block_domain" class="grid grid-cols-1 gap-3 md:grid-cols-6">
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
              <.button type="submit" variant="error" class="md:col-span-1">
                <.icon name="hero-no-symbol" class="w-4 h-4" /> Block
              </.button>
            </form>
          </div>
        </:body>
      </.card>

      <.card class="panel-card" body_class="p-0">
        <:body>
          <div class="border-b border-base-content/10 px-5 py-5 sm:px-6">
            <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <div class="text-2xs font-semibold uppercase tracking-[0.22em] text-base-content/45">
                  Peers
                </div>

                <h2 class="mt-1 flex items-center gap-2 text-xl font-semibold tracking-tight">
                  Chat Peer Policy Grid
                  <span class="badge badge-neutral">{@filtered_peer_total_count}</span>
                </h2>
              </div>

              <form phx-submit="search" class="flex gap-2">
                <input
                  type="text"
                  name="query"
                  value={@search_query}
                  placeholder="Search domain..."
                  class="input input-bordered input-sm"
                />
                <.button type="submit" size="sm">
                  <.icon name="hero-magnifying-glass" class="w-4 h-4" />
                </.button>
                <%= if Elektrine.Strings.present?(@search_query) do %>
                  <.button
                    type="button"
                    variant="ghost"
                    size="sm"
                    phx-click="clear_search"
                    data-search-clear="true"
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </.button>
                <% end %>
              </form>
            </div>
          </div>

          <div class="px-5 py-5 sm:px-6">
            <%= if @peer_controls == [] do %>
              <div class="rounded-box border border-dashed border-base-content/15 bg-base-200/45 px-4 py-8 text-center text-sm text-base-content/55">
                No peers match the current filter.
              </div>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-sm w-full">
                  <thead>
                    <tr>
                      <th>Domain</th>
                      <th>Status</th>
                      <th>Incoming Chat</th>
                      <th>Outgoing Chat</th>
                      <th class="hidden md:table-cell">Discovery / Note</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for peer <- @peer_controls do %>
                      <tr>
                        <td>
                          <div class="font-mono text-xs sm:text-sm">{peer.domain}</div>
                          <div class="flex flex-wrap gap-1 mt-1">
                            <span :if={peer.configured} class="badge badge-neutral badge-xs">
                              configured
                            </span>
                            <span :if={peer.discovered} class="badge badge-info badge-xs">
                              discovered
                            </span>
                            <span
                              :if={peer.trust_state && peer.trust_state != "trusted"}
                              class={[
                                "badge badge-xs",
                                if(peer.trust_state == "rotated",
                                  do: "badge-warning",
                                  else: "badge-error"
                                )
                              ]}
                            >
                              {peer.trust_state}
                            </span>
                            <span
                              :if={peer.requires_operator_action}
                              class="badge badge-error badge-xs"
                            >
                              review required
                            </span>
                          </div>
                          <div class="mt-1 text-xs text-base-content/55">
                            <%= cond do %>
                              <% peer.configured and peer.discovered -> %>
                                configured + discovery metadata
                              <% peer.configured -> %>
                                configured policy
                              <% peer.discovered -> %>
                                discovery cache
                              <% true -> %>
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
                          <div :if={peer.protocol_version} class="mt-1 text-xs text-base-content/55">
                            ARBP {peer.protocol_version}
                          </div>
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
                            <div class="select select-bordered select-xs">
                              <select
                                name="mode"
                                phx-change="set_direction"
                                phx-value-domain={peer.domain}
                                phx-value-direction="incoming"
                              >
                                <option
                                  value="inherit"
                                  selected={is_nil(peer.allow_incoming_override)}
                                >
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
                            <div class="select select-bordered select-xs">
                              <select
                                name="mode"
                                phx-change="set_direction"
                                phx-value-domain={peer.domain}
                                phx-value-direction="outgoing"
                              >
                                <option
                                  value="inherit"
                                  selected={is_nil(peer.allow_outgoing_override)}
                                >
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
                          </div>
                        </td>
                        <td class="hidden max-w-xs text-xs text-base-content/70 md:table-cell">
                          <div>{peer.reason || "-"}</div>
                          <div
                            :if={peer.base_url}
                            class="mt-1 font-mono text-base-content/55 break-all"
                          >
                            {peer.base_url}
                          </div>
                          <div
                            :if={peer.discovery_url}
                            class="mt-1 font-mono text-base-content/55 break-all"
                          >
                            {peer.discovery_url}
                          </div>
                          <div :if={peer.last_discovered_at} class="mt-1 text-base-content/55">
                            discovered {Calendar.strftime(
                              peer.last_discovered_at,
                              "%Y-%m-%d %H:%M:%S UTC"
                            )}
                          </div>
                          <div :if={peer.last_key_change_at} class="mt-1 text-base-content/55">
                            key change {Calendar.strftime(
                              peer.last_key_change_at,
                              "%Y-%m-%d %H:%M:%S UTC"
                            )}
                          </div>
                        </td>
                        <td>
                          <div class="flex items-center gap-1">
                            <%= if peer.blocked do %>
                              <.button
                                variant="success"
                                size="xs"
                                outline
                                phx-click="unblock_domain"
                                phx-value-domain={peer.domain}
                                title="Unblock peer"
                              >
                                <.icon name="hero-check" class="w-3 h-3" />
                                <span class="hidden lg:inline">Unblock</span>
                              </.button>
                            <% else %>
                              <.button
                                variant="error"
                                size="xs"
                                outline
                                phx-click="block_domain"
                                phx-value-domain={peer.domain}
                                phx-value-reason={peer.reason || ""}
                                title="Block peer"
                              >
                                <.icon name="hero-no-symbol" class="w-3 h-3" />
                                <span class="hidden lg:inline">Block</span>
                              </.button>
                            <% end %>
                            <.button
                              variant="ghost"
                              size="xs"
                              phx-click="clear_policy"
                              phx-value-domain={peer.domain}
                              title="Reset runtime overrides to configured defaults"
                            >
                              <.icon name="hero-arrow-path-rounded-square" class="w-3 h-3" />
                              <span class="hidden lg:inline">Reset</span>
                            </.button>
                            <.button
                              variant="ghost"
                              size="xs"
                              phx-click="refresh_discovery"
                              phx-value-domain={peer.domain}
                              title="Refresh peer discovery metadata"
                            >
                              <.icon name="hero-arrow-path" class="w-3 h-3" />
                              <span class="hidden lg:inline">Discover</span>
                            </.button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
              <%= if @total_pages > 1 do %>
                <div class="mt-4 flex items-center justify-between">
                  <span class="text-xs text-base-content/60">
                    Page {@page} of {@total_pages}
                  </span>
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
            <% end %>
          </div>
        </:body>
      </.card>
    </div>
    """
  end
end
