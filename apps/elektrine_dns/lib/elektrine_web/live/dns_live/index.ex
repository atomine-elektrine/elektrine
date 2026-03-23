defmodule ElektrineWeb.DNSLive.Index do
  use ElektrineDNSWeb, :live_view

  alias Elektrine.DNS
  alias Elektrine.DNS.Record
  alias Elektrine.DNS.Zone

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    if user do
      zones = DNS.list_user_zones(user.id)
      active_zone = select_active_zone(zones, params["zone_id"])

      {:ok,
       socket
       |> assign(:page_title, "DNS")
       |> assign(:nameservers, DNS.nameservers())
       |> assign(:authority_enabled, DNS.authority_enabled?())
       |> assign(:record_types, DNS.supported_record_types())
       |> assign(:zones, zones)
       |> assign(:active_zone, active_zone)
       |> assign(:zone_settings_form, zone_settings_form(active_zone))
       |> assign(:editing_record_id, nil)
       |> assign(:zone_form, to_form(DNS.new_zone_changeset(user.id), as: :zone))
       |> assign(:record_form, record_form(active_zone))}
    else
      {:ok,
       socket
       |> put_flash(:error, "You must be logged in to access DNS")
       |> redirect(to: ~p"/login")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    zones = DNS.list_user_zones(socket.assigns.current_user.id)
    active_zone = select_active_zone(zones, params["zone_id"])

    {:noreply,
     socket
     |> assign(:zones, zones)
     |> assign(:active_zone, active_zone)
     |> assign(:zone_settings_form, zone_settings_form(active_zone))
     |> assign(:editing_record_id, nil)
     |> assign(:record_form, record_form(active_zone))}
  end

  @impl true
  def handle_event("connection_changed", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("zone_validate", %{"zone" => params}, socket) do
    changeset =
      %Zone{}
      |> DNS.change_zone(params_with_user(socket, params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :zone_form, to_form(changeset, as: :zone))}
  end

  @impl true
  def handle_event("zone_create", %{"zone" => params}, socket) do
    case DNS.create_zone(socket.assigns.current_user, params) do
      {:ok, zone} ->
        {:noreply,
         socket
         |> put_flash(:info, "DNS zone created")
         |> push_patch(to: ~p"/dns?zone_id=#{zone.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :zone_form, to_form(%{changeset | action: :insert}, as: :zone))}
    end
  end

  @impl true
  def handle_event("zone_update", %{"zone" => params}, socket) do
    case socket.assigns.active_zone do
      %Zone{} = zone ->
        case DNS.update_zone(zone, params) do
          {:ok, zone} ->
            {:noreply,
             socket
             |> put_flash(:info, "Zone settings updated")
             |> assign(:active_zone, zone)
             |> assign(:zone_settings_form, zone_settings_form(zone))
             |> push_patch(to: ~p"/dns?zone_id=#{zone.id}")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:active_zone, %{zone | records: zone.records})
             |> assign(:zone_settings_form, to_form(%{changeset | action: :validate}, as: :zone))
             |> put_flash(:error, format_zone_error(changeset))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("zone_delete", %{"id" => id}, socket) do
    with {:ok, zone_id} <- parse_int(id),
         %Zone{} = zone <- DNS.get_zone(zone_id, socket.assigns.current_user.id),
         {:ok, _} <- DNS.delete_zone(zone) do
      {:noreply,
       socket
       |> put_flash(:info, "DNS zone deleted")
       |> push_patch(to: ~p"/dns")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not delete DNS zone")}
    end
  end

  @impl true
  def handle_event("zone_verify", %{"id" => id}, socket) do
    with {:ok, zone_id} <- parse_int(id),
         %Zone{} = zone <- DNS.get_zone(zone_id, socket.assigns.current_user.id),
         {:ok, _} <- DNS.verify_zone(zone) do
      {:noreply,
       socket
       |> put_flash(:info, "Zone verification updated")
       |> push_patch(to: ~p"/dns?zone_id=#{zone_id}")}
    else
      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, format_zone_error(changeset))}

      _ ->
        {:noreply, put_flash(socket, :error, "Zone verification failed")}
    end
  end

  @impl true
  def handle_event("record_validate", %{"record" => params}, socket) do
    case socket.assigns.active_zone do
      %Zone{} = zone ->
        changeset =
          %Record{}
          |> DNS.change_record(Map.put(params, "zone_id", zone.id))
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :record_form, to_form(changeset, as: :record))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("record_create", %{"record" => params}, socket) do
    case socket.assigns.active_zone do
      %Zone{} = zone ->
        case save_record(zone, socket.assigns.editing_record_id, params) do
          {:ok, _record} ->
            {:noreply,
             socket
             |> assign(:editing_record_id, nil)
             |> put_flash(
               :info,
               if(socket.assigns.editing_record_id,
                 do: "DNS record updated",
                 else: "DNS record created"
               )
             )
             |> push_patch(to: ~p"/dns?zone_id=#{zone.id}")}

          {:error, changeset} ->
            {:noreply,
             assign(socket, :record_form, to_form(%{changeset | action: :insert}, as: :record))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Select a zone first")}
    end
  end

  @impl true
  def handle_event("record_edit", %{"id" => id}, socket) do
    case socket.assigns.active_zone do
      %Zone{} = zone ->
        with {:ok, record_id} <- parse_int(id),
             %Record{} = record <- DNS.get_record(record_id, zone.id) do
          {:noreply,
           socket
           |> assign(:editing_record_id, record.id)
           |> assign(:record_form, to_form(DNS.change_record(record), as: :record))}
        else
          _ -> {:noreply, put_flash(socket, :error, "Could not load record for editing")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("record_cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_record_id, nil)
     |> assign(:record_form, record_form(socket.assigns.active_zone))}
  end

  @impl true
  def handle_event("record_delete", %{"id" => id}, socket) do
    case socket.assigns.active_zone do
      %Zone{} = zone ->
        with {:ok, record_id} <- parse_int(id),
             %Record{} = record <- DNS.get_record(record_id, zone.id),
             {:ok, _} <- DNS.delete_record(record) do
          {:noreply,
           socket
           |> put_flash(:info, "DNS record deleted")
           |> push_patch(to: ~p"/dns?zone_id=#{zone.id}")}
        else
          _ -> {:noreply, put_flash(socket, :error, "Could not delete record")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl space-y-6 px-4 pb-2 sm:px-6 lg:px-8">
      <.e_nav active_tab="dns" current_user={@current_user} class="mb-6" />

      <div class="card glass-card shadow-lg">
        <div class="card-body p-6">
          <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <h1 class="card-title text-2xl">DNS</h1>
              <p class="text-base-content/70">Manage authoritative zones on Elektrine nameservers.</p>
            </div>

            <div class="badge badge-outline">
              <%= if @authority_enabled do %>
                Authority runtime enabled
              <% else %>
                Authority runtime disabled
              <% end %>
            </div>
          </div>

          <div class="mt-4 rounded-lg border border-base-300 bg-base-200/50 p-4">
            <p class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              Nameservers
            </p>
            <ul class="mt-2 grid gap-1 font-mono text-sm md:grid-cols-2">
              <%= for ns <- @nameservers do %>
                <li>{ns}</li>
              <% end %>
            </ul>
          </div>
        </div>
      </div>

      <div class="grid gap-6 xl:grid-cols-[1.1fr_1.4fr]">
        <div class="space-y-6">
          <div class="card glass-card shadow-lg">
            <div class="card-body p-6">
              <h2 class="card-title text-lg">New zone</h2>
              <.simple_form
                for={@zone_form}
                bare={true}
                phx-change="zone_validate"
                phx-submit="zone_create"
              >
                <.input field={@zone_form[:domain]} label="Domain" placeholder="example.com" required />
                <.input field={@zone_form[:default_ttl]} type="number" label="Default TTL" />
                <:actions>
                  <.button>Provision zone</.button>
                </:actions>
              </.simple_form>
            </div>
          </div>

          <div class="card glass-card shadow-lg">
            <div class="card-body p-6">
              <h2 class="card-title text-lg">Zones</h2>

              <%= if @zones == [] do %>
                <p class="text-base-content/70">No DNS zones yet.</p>
              <% else %>
                <div class="space-y-3">
                  <%= for zone <- @zones do %>
                    <.link
                      navigate={~p"/dns?zone_id=#{zone.id}"}
                      class={zone_link_class(zone, @active_zone)}
                    >
                      <div>
                        <p class="font-medium">{zone.domain}</p>
                        <p class="text-xs text-base-content/60">
                          {zone.status} · serial {zone.serial}
                        </p>
                      </div>
                      <span class="text-xs font-mono">TTL {zone.default_ttl}</span>
                    </.link>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%= if @active_zone do %>
          <div class="space-y-6">
            <div class="card glass-card shadow-lg">
              <div class="card-body p-6">
                <h3 class="card-title text-lg">Zone settings</h3>
                <.simple_form
                  for={@zone_settings_form}
                  bare={true}
                  phx-submit="zone_update"
                >
                  <div class="grid gap-4 md:grid-cols-2">
                    <.input
                      field={@zone_settings_form[:default_ttl]}
                      type="number"
                      label="Default TTL"
                    />
                    <.input
                      field={@zone_settings_form[:serial]}
                      type="number"
                      label="Serial"
                    />
                    <.input
                      field={@zone_settings_form[:soa_mname]}
                      label="SOA MNAME"
                    />
                    <.input
                      field={@zone_settings_form[:soa_rname]}
                      label="SOA RNAME"
                    />
                    <.input
                      field={@zone_settings_form[:soa_refresh]}
                      type="number"
                      label="SOA Refresh"
                    />
                    <.input
                      field={@zone_settings_form[:soa_retry]}
                      type="number"
                      label="SOA Retry"
                    />
                    <.input
                      field={@zone_settings_form[:soa_expire]}
                      type="number"
                      label="SOA Expire"
                    />
                    <.input
                      field={@zone_settings_form[:soa_minimum]}
                      type="number"
                      label="SOA Minimum"
                    />
                  </div>
                  <:actions>
                    <.button>Save zone metadata</.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>

            <div class="card glass-card shadow-lg">
              <div class="card-body p-6">
                <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                  <div>
                    <h2 class="card-title text-lg">{@active_zone.domain}</h2>
                    <p class="text-sm text-base-content/70">
                      Point the zone at these nameservers, then verify.
                    </p>
                  </div>
                  <div class="flex gap-2">
                    <button
                      type="button"
                      phx-click="zone_verify"
                      phx-value-id={@active_zone.id}
                      class="btn btn-sm btn-primary"
                    >
                      Verify
                    </button>
                    <button
                      type="button"
                      phx-click="zone_delete"
                      phx-value-id={@active_zone.id}
                      data-confirm="Delete this DNS zone and all records?"
                      class="btn btn-sm btn-error btn-outline"
                    >
                      Delete
                    </button>
                  </div>
                </div>

                <%= if @active_zone.last_error do %>
                  <div class="alert alert-warning mt-4 text-sm">{@active_zone.last_error}</div>
                <% end %>

                <div class="mt-4 overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Type</th>
                        <th>Host</th>
                        <th>Value</th>
                        <th>Priority</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for record <- DNS.zone_onboarding_records(@active_zone) do %>
                        <tr>
                          <td>{record.type}</td>
                          <td class="font-mono text-xs">{record.host}</td>
                          <td class="font-mono text-xs break-all">{record.value}</td>
                          <td>{record.priority || "-"}</td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>

            <div class="card glass-card shadow-lg">
              <div class="card-body p-6">
                <div class="flex items-center justify-between gap-3">
                  <h3 class="card-title text-lg">
                    <%= if @editing_record_id do %>
                      Edit record
                    <% else %>
                      Add record
                    <% end %>
                  </h3>

                  <%= if @editing_record_id do %>
                    <button type="button" phx-click="record_cancel_edit" class="btn btn-sm btn-ghost">
                      Cancel edit
                    </button>
                  <% end %>
                </div>
                <.simple_form
                  for={@record_form}
                  bare={true}
                  phx-change="record_validate"
                  phx-submit="record_create"
                >
                  <div class="grid gap-4 md:grid-cols-2">
                    <.input field={@record_form[:name]} label="Name" placeholder="@ or www" required />
                    <.input
                      field={@record_form[:type]}
                      type="select"
                      label="Type"
                      options={Enum.map(@record_types, &{&1, &1})}
                    />
                    <.input
                      field={@record_form[:content]}
                      label="Value"
                      placeholder="198.51.100.42"
                      required
                    />
                    <.input field={@record_form[:ttl]} type="number" label="TTL" />
                    <.input field={@record_form[:priority]} type="number" label="Priority (MX/SRV)" />
                    <.input field={@record_form[:weight]} type="number" label="Weight (SRV)" />
                    <.input field={@record_form[:port]} type="number" label="Port (SRV)" />
                    <.input field={@record_form[:flags]} type="number" label="Flags (CAA)" />
                    <.input field={@record_form[:tag]} label="Tag (CAA)" placeholder="issue" />
                  </div>
                  <:actions>
                    <.button>
                      <%= if @editing_record_id do %>
                        Save changes
                      <% else %>
                        Add DNS record
                      <% end %>
                    </.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>

            <div class="card glass-card shadow-lg">
              <div class="card-body p-6">
                <h3 class="card-title text-lg">Records</h3>
                <%= if @active_zone.records == [] do %>
                  <p class="text-base-content/70">No custom records yet.</p>
                <% else %>
                  <div class="overflow-x-auto">
                    <table class="table">
                      <thead>
                        <tr>
                          <th>Name</th>
                          <th>Type</th>
                          <th>Value</th>
                          <th>TTL</th>
                          <th></th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for record <- @active_zone.records do %>
                          <tr>
                            <td>{record.name}</td>
                            <td>{record.type}</td>
                            <td class="font-mono text-xs break-all">{record.content}</td>
                            <td>{record.ttl}</td>
                            <td>
                              <div class="flex gap-2">
                                <button
                                  type="button"
                                  phx-click="record_edit"
                                  phx-value-id={record.id}
                                  class="btn btn-xs btn-outline"
                                >
                                  Edit
                                </button>
                                <button
                                  type="button"
                                  phx-click="record_delete"
                                  phx-value-id={record.id}
                                  data-confirm="Delete this DNS record?"
                                  class="btn btn-xs btn-error btn-outline"
                                >
                                  Delete
                                </button>
                              </div>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp params_with_user(socket, params),
    do: Map.put(params, "user_id", socket.assigns.current_user.id)

  defp select_active_zone([], _zone_id), do: nil
  defp select_active_zone(zones, nil), do: List.first(zones)

  defp select_active_zone(zones, zone_id) do
    case parse_int(zone_id) do
      {:ok, zone_id} -> Enum.find(zones, List.first(zones), &(&1.id == zone_id))
      :error -> List.first(zones)
    end
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_int(_), do: :error

  defp record_form(nil), do: to_form(DNS.change_record(%Record{}, %{}), as: :record)

  defp record_form(%Zone{id: zone_id}),
    do: to_form(DNS.new_record_changeset(zone_id), as: :record)

  defp zone_settings_form(nil), do: nil

  defp zone_settings_form(%Zone{} = zone),
    do: to_form(DNS.change_zone(zone), as: :zone)

  defp save_record(zone, nil, params), do: DNS.create_record(zone, params)

  defp save_record(zone, record_id, params) do
    with %Record{} = record <- DNS.get_record(record_id, zone.id) do
      DNS.update_record(record, params)
    else
      _ -> {:error, DNS.change_record(%Record{}, params) |> Map.put(:action, :insert)}
    end
  end

  defp zone_link_class(zone, active_zone) do
    active? = active_zone && zone.id == active_zone.id

    [
      "flex items-center justify-between rounded-lg border px-4 py-3 transition",
      if(active?,
        do: "border-primary bg-primary/10",
        else: "border-base-300 bg-base-200/50 hover:border-primary/40"
      )
    ]
  end

  defp format_zone_error(changeset) do
    changeset.errors
    |> Keyword.keys()
    |> Enum.map_join(", ", &to_string/1)
    |> case do
      "" -> "Zone verification failed"
      details -> "Zone verification failed (#{details})"
    end
  end
end
