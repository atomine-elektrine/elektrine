defmodule ElektrineDNSWeb.DNSLive.Index do
  use ElektrineDNSWeb, :live_view

  alias Elektrine.Accounts.User
  alias Elektrine.DNS
  alias Elektrine.DNS.MailSecurity
  alias Elektrine.DNS.Record
  alias Elektrine.DNS.Zone
  alias Elektrine.Profiles.CustomDomains, as: ProfileCustomDomains

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    if user do
      zones = DNS.list_user_zones(user)
      active_zone = select_active_zone(zones, params["zone_id"])

      {:ok,
       socket
       |> assign(:page_title, "DNS")
       |> assign(:nameservers, DNS.nameservers())
       |> assign(:record_types, DNS.supported_record_types())
       |> assign(:zones, zones)
       |> assign(:active_zone, active_zone)
       |> assign(:linked_domains, linked_domains(active_zone, user.id))
       |> assign(:domain_health, DNS.domain_health(active_zone))
       |> assign(:service_health, service_health(active_zone))
       |> assign(:service_forms, service_forms(active_zone))
       |> assign(:zone_settings_form, zone_settings_form(active_zone))
       |> assign(:editing_record_id, nil)
       |> assign(:selected_record_preset, nil)
       |> assign(:zone_form, to_form(DNS.new_zone_changeset(user.id), as: :zone))
       |> assign(:zone_scan, nil)
       |> assign(:record_form, record_form(active_zone))}
    else
      {:ok,
       socket
       |> put_flash(:error, "You must be logged in to access DNS")
       |> redirect(to: Elektrine.Paths.login_path())}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    zones = DNS.list_user_zones(socket.assigns.current_user)
    active_zone = select_active_zone(zones, params["zone_id"])

    {:noreply,
     socket
     |> assign(:zones, zones)
     |> assign(:active_zone, active_zone)
     |> assign(:linked_domains, linked_domains(active_zone, socket.assigns.current_user.id))
     |> assign(:domain_health, DNS.domain_health(active_zone))
     |> assign(:service_health, service_health(active_zone))
     |> assign(:service_forms, service_forms(active_zone))
     |> assign(:zone_settings_form, zone_settings_form(active_zone))
     |> assign(:editing_record_id, nil)
     |> assign(:selected_record_preset, nil)
     |> assign(:zone_scan, socket.assigns[:zone_scan])
     |> assign(:record_form, record_form(active_zone))}
  end

  @impl true
  def handle_event("zone_validate", %{"zone" => params}, socket) do
    changeset =
      %Zone{}
      |> DNS.change_zone(params_with_user(socket, params))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:zone_form, to_form(changeset, as: :zone))
     |> assign(:zone_scan, keep_matching_scan(socket.assigns.zone_scan, params))}
  end

  @impl true
  def handle_event("zone_submit", %{"zone" => params, "_action" => "scan"}, socket) do
    changeset =
      %Zone{}
      |> DNS.change_zone(params_with_user(socket, params))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:zone_form, to_form(changeset, as: :zone))
     |> assign(:zone_scan, zone_scan_for_params(params))}
  end

  @impl true
  def handle_event("zone_submit", %{"zone" => params, "_action" => "create"}, socket) do
    case DNS.create_zone(socket.assigns.current_user, params) do
      {:ok, zone} ->
        {:noreply,
         socket
         |> assign(:zone_scan, nil)
         |> put_flash(:info, "DNS zone created")
         |> push_patch(to: ~p"/dns?zone_id=#{zone.id}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:zone_form, to_form(%{changeset | action: :insert}, as: :zone))
         |> assign(:zone_scan, zone_scan_for_params(params))}
    end
  end

  @impl true
  def handle_event("scan_import", params, socket) do
    case socket.assigns.zone_scan do
      nil ->
        {:noreply, put_flash(socket, :error, "No scan results to import")}

      scan ->
        selected_ids = Map.get(params, "selected_records", [])

        if selected_ids == [] do
          {:noreply, put_flash(socket, :error, "Select at least one record to import")}
        else
          case matching_scan_zone(socket.assigns.zones, scan) do
            %Zone{} = zone ->
              {:noreply,
               socket
               |> put_flash(
                 :info,
                 scan_import_message(import_scan_records(zone, scan, selected_ids), false)
               )
               |> push_patch(to: ~p"/dns?zone_id=#{zone.id}")}

            nil ->
              case DNS.create_zone(
                     socket.assigns.current_user,
                     zone_form_attrs(socket.assigns.zone_form)
                   ) do
                {:ok, zone} ->
                  {:noreply,
                   socket
                   |> assign(:zone_scan, nil)
                   |> put_flash(
                     :info,
                     scan_import_message(import_scan_records(zone, scan, selected_ids), true)
                   )
                   |> push_patch(to: ~p"/dns?zone_id=#{zone.id}")}

                {:error, changeset} ->
                  {:noreply,
                   socket
                   |> assign(:zone_form, to_form(%{changeset | action: :insert}, as: :zone))
                   |> put_flash(:error, format_zone_error(changeset))}
              end
          end
        end
    end
  end

  @impl true
  def handle_event("zone_update", %{"zone" => params}, socket) do
    case socket.assigns.active_zone do
      %Zone{} = zone ->
        case DNS.update_zone(zone, normalize_zone_params(params)) do
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
  def handle_event("builtin_zone_mode_set", %{"mode" => mode}, socket) do
    case DNS.update_builtin_user_zone_mode(socket.assigns.current_user, mode) do
      {:ok, user} ->
        zones = DNS.list_user_zones(user)

        active_zone =
          select_active_zone(zones, socket.assigns.active_zone && socket.assigns.active_zone.id)

        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:zones, zones)
         |> assign(:active_zone, active_zone)
         |> assign(:linked_domains, linked_domains(active_zone, user.id))
         |> assign(:service_health, service_health(active_zone))
         |> assign(:service_forms, service_forms(active_zone))
         |> assign(:zone_settings_form, zone_settings_form(active_zone))
         |> assign(:record_form, record_form(active_zone))
         |> put_flash(
           :info,
           if(DNS.builtin_user_zone_hosted_by_platform?(user),
             do: "Built-in subdomain returned to Elektrine hosting",
             else: "Built-in subdomain handed off to DNS"
           )
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, format_user_error(changeset))}

      {:error, :invalid_mode} ->
        {:noreply, put_flash(socket, :error, "Invalid built-in subdomain mode")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not update built-in subdomain mode")}
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
             |> assign(:selected_record_preset, nil)
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
           |> assign(:selected_record_preset, nil)
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
     |> assign(:selected_record_preset, nil)
     |> assign(:record_form, record_form(socket.assigns.active_zone))}
  end

  @impl true
  def handle_event("record_preset", %{"preset" => preset}, socket) do
    case socket.assigns.active_zone do
      %Zone{} = zone ->
        {:noreply,
         socket
         |> assign(:editing_record_id, nil)
         |> assign(:selected_record_preset, preset)
         |> assign(:record_form, record_form(zone, record_preset_attrs(zone, preset)))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("record_type_preset", %{"type" => type}, socket) do
    case socket.assigns.active_zone do
      %Zone{} = zone ->
        {:noreply,
         socket
         |> assign(:editing_record_id, nil)
         |> assign(:selected_record_preset, nil)
         |> assign(:record_form, record_form(zone, record_type_preset_attrs(zone, type)))}

      _ ->
        {:noreply, socket}
    end
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
  def handle_event("service_apply", %{"service" => service, "service_config" => params}, socket) do
    case socket.assigns.active_zone do
      %Zone{} = zone ->
        attrs = %{"settings" => Map.drop(params, ["service"])}

        case DNS.apply_zone_service(zone, service, attrs) do
          {:ok, _config} ->
            {:noreply,
             socket
             |> put_flash(:info, "Managed #{String.capitalize(service)} DNS applied")
             |> push_patch(to: ~p"/dns?zone_id=#{zone.id}")}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, format_service_error(service, changeset))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("service_disable", %{"service" => service}, socket) do
    case socket.assigns.active_zone do
      %Zone{} = zone ->
        case DNS.disable_zone_service(zone, service) do
          {:ok, _config} ->
            {:noreply,
             socket
             |> put_flash(:info, "Managed #{String.capitalize(service)} DNS disabled")
             |> push_patch(to: ~p"/dns?zone_id=#{zone.id}")}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, format_service_error(service, changeset))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("linked_domain_apply", %{"kind" => kind, "domain" => domain}, socket) do
    case {socket.assigns.active_zone,
          load_linked_custom_domain(kind, domain, socket.assigns.current_user.id)} do
      {%Zone{} = zone, {:ok, linked_domain, linked_kind}} ->
        result =
          linked_domain
          |> expected_linked_domain_records(linked_kind)
          |> Enum.reject(&record_exists_for_expected?(zone, &1))
          |> Enum.reduce_while({:ok, 0}, fn expected_record, {:ok, count} ->
            case DNS.create_record(zone, expected_record_to_attrs(zone, expected_record)) do
              {:ok, _record} -> {:cont, {:ok, count + 1}}
              {:error, changeset} -> {:halt, {:error, changeset}}
            end
          end)

        case result do
          {:ok, 0} ->
            {:noreply, put_flash(socket, :info, "No missing records to add")}

          {:ok, count} ->
            {:noreply,
             socket
             |> put_flash(:info, "Added #{count} DNS record#{if count == 1, do: "", else: "s"}")
             |> push_patch(to: ~p"/dns?zone_id=#{zone.id}")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not add the linked domain records")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Could not load linked custom domain")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl px-4 pb-8 sm:px-6 lg:px-8">
      <.e_nav active_tab="dns" current_user={@current_user} class="mb-6" />

      <div class="grid gap-6 xl:grid-cols-[320px_minmax(0,1fr)]">
        <aside class="space-y-6">
          <section class="card panel-card">
            <div class="card-body p-0">
              <div class="border-b border-base-content/10 px-5 py-4">
                <div class="mb-3 flex items-center justify-between gap-3">
                  <h1 class="text-lg font-semibold text-base-content">DNS</h1>

                  <div class="badge badge-outline badge-sm">
                    {length(@zones)} zone{if length(@zones) == 1, do: "", else: "s"}
                  </div>
                </div>

                <h2 class="text-sm font-semibold uppercase tracking-[0.16em] text-base-content/60">
                  Zones
                </h2>
                <p class="mt-1 text-sm text-base-content/65">
                  Pick a domain on the left, then add records like `www` or `mail` relative to it.
                </p>
              </div>

              <%= if @zones == [] do %>
                <div class="px-5 py-4 text-sm text-base-content/65">No zones yet.</div>
              <% else %>
                <div class="overflow-hidden">
                  <div class="grid grid-cols-[minmax(0,1fr)_112px_44px] gap-3 border-b border-base-content/10 px-5 py-2 text-[11px] font-semibold uppercase tracking-[0.16em] text-base-content/50">
                    <span>Zone</span>
                    <span>Status</span>
                    <span class="text-right">TTL</span>
                  </div>
                  <%= for zone <- @zones do %>
                    <.link
                      navigate={~p"/dns?zone_id=#{zone.id}"}
                      class={compact_zone_link_class(zone, @active_zone)}
                    >
                      <div class="min-w-0 pr-2">
                        <p class="truncate font-mono text-sm">{zone.domain}</p>
                        <p class="truncate text-xs text-base-content/55">
                          {zone_role_label(zone, @current_user)}
                        </p>
                      </div>
                      <span class={[zone_status_badge_class(zone.status), "justify-self-start"]}>
                        {zone.status}
                      </span>
                      <span class="text-right text-xs font-mono text-base-content/70">
                        {zone.default_ttl}
                      </span>
                    </.link>
                  <% end %>
                </div>
              <% end %>

              <div class="border-t border-base-content/10 px-5 py-4">
                <div class="mb-4">
                  <h3 class="text-sm font-semibold uppercase tracking-[0.16em] text-base-content/60">
                    New zone
                  </h3>
                  <p class="mt-1 text-sm text-base-content/65">
                    Start with the domain you own, like `example.com`. You can import its current public records first if you want.
                  </p>
                </div>

                <.simple_form
                  id="new-zone-form"
                  for={@zone_form}
                  bare={true}
                  phx-change="zone_validate"
                  phx-submit="zone_submit"
                >
                  <div class="grid gap-x-4 gap-y-4 md:grid-cols-[minmax(0,1fr)_160px] xl:grid-cols-1">
                    <.input
                      field={@zone_form[:domain]}
                      label="Domain"
                      placeholder="example.com"
                      required
                    />
                    <div class="space-y-2">
                      <.input field={@zone_form[:default_ttl]} type="number" label="Default TTL" />
                      <p class="text-xs text-base-content/55">
                        TTL is how long other DNS servers cache answers. `3600` seconds (1 hour) is a safe default.
                      </p>
                    </div>
                  </div>
                  <div class="mt-4 space-y-2">
                    <.button
                      type="submit"
                      name="_action"
                      value="scan"
                      variant="secondary"
                      class="w-full phx-submit-loading:pointer-events-none phx-submit-loading:opacity-80"
                    >
                      <span class="phx-submit-loading:hidden">Scan public DNS</span>
                      <span class="hidden items-center gap-2 phx-submit-loading:inline-flex">
                        <.spinner size="sm" />
                        <span>Scan public DNS</span>
                      </span>
                    </.button>
                    <p class="text-xs text-base-content/60">
                      Runs a one-time lookup for the current domain and lets you choose what to import.
                    </p>
                  </div>
                  <:actions>
                    <.button
                      name="_action"
                      value="create"
                      class="phx-submit-loading:pointer-events-none phx-submit-loading:opacity-80"
                    >
                      <span class="phx-submit-loading:hidden">Provision zone</span>
                      <span class="hidden items-center gap-2 phx-submit-loading:inline-flex">
                        <.spinner size="sm" />
                        <span>Provisioning...</span>
                      </span>
                    </.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
          </section>
        </aside>

        <main :if={@active_zone || @zone_scan} class="space-y-6">
          <%= if @zone_scan do %>
            <section class="card panel-card">
              <div class="card-body p-5 sm:p-6">
                <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                  <div>
                    <div class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                      Public DNS
                    </div>
                    <div class="mt-1 text-sm text-base-content/70">
                      Current public records for <span class="font-mono">{@zone_scan.domain}</span>
                    </div>
                  </div>
                  <div class="flex flex-wrap items-center gap-2">
                    <%= if @zone_scan.provider_hint do %>
                      <span class="badge badge-outline">{@zone_scan.provider_hint}</span>
                    <% end %>
                    <span class={[
                      "badge badge-outline",
                      if(@zone_scan.delegated_to_elektrine,
                        do: "badge-success",
                        else: "badge-warning"
                      )
                    ]}>
                      <%= if @zone_scan.delegated_to_elektrine do %>
                        Delegated to Elektrine
                      <% else %>
                        Delegation points elsewhere
                      <% end %>
                    </span>
                  </div>
                </div>

                <.form for={%{}} as={:scan} phx-submit="scan_import" class="mt-4 space-y-5">
                  <div class="flex flex-col gap-3 rounded-xl border border-base-content/10 bg-base-200/20 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
                    <p class="text-sm text-base-content/70">
                      <%= if matching_scan_zone(@zones, @zone_scan) do %>
                        Select the public records you want to import into the matching Elektrine zone.
                      <% else %>
                        Select the public records you want to bring over when provisioning this zone.
                      <% end %>
                    </p>
                    <button
                      type="submit"
                      class="btn btn-primary btn-sm phx-submit-loading:pointer-events-none phx-submit-loading:opacity-80"
                    >
                      <span class="phx-submit-loading:hidden">
                        <%= if matching_scan_zone(@zones, @zone_scan) do %>
                          Import selected records
                        <% else %>
                          Provision and import selected
                        <% end %>
                      </span>
                      <span class="hidden items-center gap-2 phx-submit-loading:inline-flex">
                        <.spinner size="sm" />
                        <span>Importing...</span>
                      </span>
                    </button>
                  </div>

                  <div class="grid gap-5 xl:grid-cols-[320px_minmax(0,1fr)]">
                    <div>
                      <div class="text-[11px] font-semibold uppercase tracking-[0.18em] text-base-content/45">
                        Nameservers
                      </div>
                      <div class="mt-2 rounded-xl border border-base-content/10 bg-base-200/20 p-3 font-mono text-xs break-all text-base-content/80">
                        <%= if @zone_scan.nameservers == [] do %>
                          No nameservers detected.
                        <% else %>
                          {format_scan_values(@zone_scan.nameservers)}
                        <% end %>
                      </div>
                    </div>

                    <div
                      :if={scan_import_items(@zone_scan) != []}
                      class="overflow-hidden rounded-xl border border-base-content/10 bg-base-100"
                    >
                      <div class="grid grid-cols-[56px_88px_72px_minmax(0,1fr)] gap-3 border-b border-base-content/10 px-4 py-3 text-[11px] font-semibold uppercase tracking-[0.16em] text-base-content/50">
                        <span>Add</span>
                        <span>Host</span>
                        <span>Type</span>
                        <span>Value</span>
                      </div>
                      <div class="divide-y divide-base-content/10">
                        <%= for item <- scan_import_items(@zone_scan) do %>
                          <label class="grid cursor-pointer gap-3 px-4 py-3 text-sm sm:grid-cols-[56px_88px_72px_minmax(0,1fr)]">
                            <input
                              type="checkbox"
                              name="selected_records[]"
                              value={item.id}
                              checked
                              class="checkbox checkbox-sm mt-0.5"
                            />
                            <div class="font-mono text-base-content/70">{item.host}</div>
                            <div class="font-mono text-base-content/70">{item.type}</div>
                            <div class="font-mono break-all text-base-content/85">{item.value}</div>
                          </label>
                        <% end %>
                      </div>
                    </div>
                  </div>
                </.form>
              </div>
            </section>
          <% end %>

          <section :if={@active_zone} class="card panel-card">
            <div class="card-body p-0">
              <div class="flex flex-col gap-5 border-b border-base-content/10 px-5 py-4 lg:flex-row lg:items-start lg:justify-between">
                <div class="space-y-3">
                  <div>
                    <h2 class="font-mono text-xl font-semibold tracking-tight">
                      {@active_zone.domain}
                    </h2>
                    <p class="mt-1 text-sm text-base-content/65">
                      {zone_description(@active_zone, @current_user)}
                    </p>
                  </div>

                  <div class="flex flex-wrap items-center gap-2">
                    <span class={zone_status_badge_class(@active_zone.status)}>
                      {@active_zone.status}
                    </span>
                    <%= if builtin_zone?(@active_zone, @current_user) do %>
                      <span class="badge badge-info badge-outline">built-in</span>
                      <span class="badge badge-outline">
                        {builtin_zone_mode_label(@current_user)}
                      </span>
                    <% end %>
                    <span class="badge badge-ghost">TTL {@active_zone.default_ttl}</span>
                    <%= if @active_zone.verified_at do %>
                      <span class="badge badge-outline">
                        Verified {Calendar.strftime(@active_zone.verified_at, "%Y-%m-%d")}
                      </span>
                    <% end %>
                  </div>
                </div>

                <div class="flex flex-wrap gap-2">
                  <.link
                    navigate={~p"/account/profile/domains/analytics?zone_id=#{@active_zone.id}"}
                    class="btn btn-sm btn-outline"
                  >
                    <.icon name="hero-chart-bar" class="h-4 w-4" /> Analytics
                  </.link>
                  <%= if builtin_zone?(@active_zone, @current_user) do %>
                    <span class="text-sm text-base-content/60">
                      {if builtin_zone_hosted_by_platform?(@current_user),
                        do: "Apex remains reserved for Elektrine.",
                        else: "Apex is user-managed in DNS."}
                    </span>
                  <% else %>
                    <button
                      type="button"
                      phx-click="zone_verify"
                      phx-value-id={@active_zone.id}
                      class="btn btn-sm btn-primary"
                    >
                      <.icon name="hero-check-badge" class="h-4 w-4" /> Check setup
                    </button>
                    <button
                      type="button"
                      phx-click="zone_delete"
                      phx-value-id={@active_zone.id}
                      data-confirm="Delete this DNS zone and all records?"
                      class="btn btn-sm btn-error btn-outline"
                    >
                      <.icon name="hero-trash" class="h-4 w-4" /> Delete
                    </button>
                  <% end %>
                </div>
              </div>

              <div class="space-y-5 px-5 py-4">
                <%= if builtin_zone?(@active_zone, @current_user) do %>
                  <div class="rounded-2xl border border-info/20 bg-info/5 px-4 py-3 text-sm">
                    <%= if builtin_zone_hosted_by_platform?(@current_user) do %>
                      <span>
                        <code>{@active_zone.domain}</code>
                        is the built-in host for your profile/static site. Apex `@` stays platform-managed; user records can be added on descendant labels plus apex `TXT` and `CAA`.
                      </span>
                    <% else %>
                      <span>
                        <code>{@active_zone.domain}</code>
                        is handed off to DNS. Elektrine will not serve the built-in profile/static site on this host until you switch it back.
                      </span>
                    <% end %>
                  </div>

                  <div class="rounded-2xl border border-base-content/10 bg-base-200/20 px-4 py-4">
                    <div class="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
                      <div class="space-y-1">
                        <h3 class="text-sm font-semibold uppercase tracking-[0.16em] text-base-content/60">
                          Built-in host ownership
                        </h3>
                        <p class="text-sm text-base-content/65">
                          Switch between platform-managed apex routing and full user DNS control.
                        </p>
                      </div>
                      <div class="join self-start lg:self-auto">
                        <button
                          type="button"
                          phx-click="builtin_zone_mode_set"
                          phx-value-mode="platform"
                          class={builtin_zone_mode_button_class(@current_user, "platform")}
                        >
                          Platform
                        </button>
                        <button
                          type="button"
                          phx-click="builtin_zone_mode_set"
                          phx-value-mode="external_dns"
                          class={builtin_zone_mode_button_class(@current_user, "external_dns")}
                        >
                          External DNS
                        </button>
                      </div>
                    </div>
                  </div>
                <% end %>

                <%= if @active_zone.last_error do %>
                  <div class="rounded-xl border border-warning/20 bg-warning/10 px-4 py-3 text-sm">
                    {@active_zone.last_error}
                  </div>
                <% end %>

                <%= if not builtin_zone?(@active_zone, @current_user) do %>
                  <div class="rounded-2xl border border-base-content/10 bg-base-200/20 px-4 py-4">
                    <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                      <div class="space-y-1">
                        <h3 class="text-sm font-semibold uppercase tracking-[0.16em] text-base-content/60">
                          Quick start
                        </h3>
                        <p class="text-sm text-base-content/65">
                          Follow these steps to move this domain onto Elektrine DNS.
                        </p>
                      </div>
                      <span class={zone_status_badge_class(@active_zone.status)}>
                        {@active_zone.status}
                      </span>
                    </div>
                    <div class="mt-4 grid gap-3 xl:grid-cols-3">
                      <div class="rounded-xl border border-base-content/10 bg-base-100 px-3 py-3 text-sm">
                        <p class="font-semibold">1. Point your registrar here</p>
                        <p class="mt-1 text-base-content/65">
                          Replace your current nameservers with the Elektrine nameservers shown below.
                        </p>
                      </div>
                      <div class="rounded-xl border border-base-content/10 bg-base-100 px-3 py-3 text-sm">
                        <p class="font-semibold">2. Wait for DNS to update</p>
                        <p class="mt-1 text-base-content/65">
                          Registrar changes can take a little while to spread. This is normal.
                        </p>
                      </div>
                      <div class="rounded-xl border border-base-content/10 bg-base-100 px-3 py-3 text-sm">
                        <p class="font-semibold">3. Check setup here</p>
                        <p class="mt-1 text-base-content/65">
                          When the nameserver change is live, use the button above to verify the zone.
                        </p>
                      </div>
                    </div>
                  </div>
                <% end %>

                <.simple_form
                  for={@zone_settings_form}
                  bare={true}
                  phx-submit="zone_update"
                  class="rounded-2xl border border-base-content/10 bg-base-200/20 px-4 py-4"
                >
                  <div class="mb-4">
                    <h3 class="text-sm font-semibold uppercase tracking-[0.16em] text-base-content/60">
                      Zone settings
                    </h3>
                    <p class="mt-1 text-sm text-base-content/65">
                      Applies to records created inside this zone.
                    </p>
                  </div>
                  <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
                    <.input
                      field={@zone_settings_form[:default_ttl]}
                      type="number"
                      label="Default TTL"
                    />
                    <.input
                      field={@zone_settings_form[:force_https]}
                      type="checkbox"
                      label="Force HTTPS"
                    />
                  </div>
                  <:actions>
                    <.button>Save settings</.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
          </section>

          <div class="space-y-6">
            <section class="card panel-card">
              <div class="card-body p-0">
                <div class="border-b border-base-content/10 px-5 py-4">
                  <h3 class="text-sm font-semibold uppercase tracking-[0.16em] text-base-content/60">
                    Records
                  </h3>
                  <p class="mt-1 text-sm text-base-content/65">
                    `@` means the apex of the selected zone. Managed records are read-only here.
                  </p>
                </div>
                <div class="p-5">
                  <%= if @editing_record_id do %>
                    <div class="mb-5 rounded-2xl border border-base-content/10 bg-base-200/20 p-4">
                      <div class="mb-4 space-y-1">
                        <h4 class="font-semibold">Edit record</h4>
                        <p class="text-sm text-base-content/65">
                          Update the label, type, TTL, and type-specific fields.
                        </p>
                      </div>
                      <.simple_form
                        for={@record_form}
                        bare={true}
                        phx-change="record_validate"
                        phx-submit="record_create"
                      >
                        <div class="grid gap-x-4 gap-y-5 md:grid-cols-2 xl:grid-cols-3">
                          <.input
                            field={@record_form[:name]}
                            label="Name"
                            placeholder="@ or www"
                            required
                          />
                          <p class="text-xs text-base-content/55">
                            {record_name_field_help(@active_zone, @current_user)}
                          </p>
                          <.input
                            field={@record_form[:type]}
                            type="select"
                            label="Type"
                            options={Enum.map(@record_types, &{&1, &1})}
                          />
                          <p class="text-xs text-base-content/55">{record_type_help(@record_form)}</p>
                          <% value_spec = record_value_spec(@record_form) %>
                          <.input
                            field={@record_form[:content]}
                            label={value_spec.label}
                            placeholder={value_spec.placeholder}
                            required
                          />
                          <p class="text-xs text-base-content/55">
                            {record_value_help(@record_form)}
                          </p>
                          <.input field={@record_form[:ttl]} type="number" label="TTL" />
                          <p class="text-xs text-base-content/55">{ttl_help_text(@active_zone)}</p>
                          <.input
                            field={@record_form[:private]}
                            type="checkbox"
                            label="Private record"
                          />
                          <p class="text-xs text-base-content/55">
                            Only recursive/private DNS clients can resolve this record. Public authoritative queries will not receive it.
                          </p>
                          <%= for spec <- record_param_specs(@record_form) do %>
                            <.input
                              field={@record_form[spec.field]}
                              type={spec.type}
                              label={spec.label}
                              placeholder={spec.placeholder}
                            />
                          <% end %>
                        </div>
                        <:actions>
                          <.button>Save changes</.button>
                        </:actions>
                      </.simple_form>
                      <div class="pt-1">
                        <button
                          type="button"
                          phx-click="record_cancel_edit"
                          class="link link-hover text-sm text-base-content/65"
                        >
                          Cancel edit
                        </button>
                      </div>
                    </div>
                  <% end %>

                  <%= if @active_zone.records == [] do %>
                    <div class="text-sm text-base-content/65">No records yet.</div>
                  <% else %>
                    <div class="overflow-x-auto rounded-2xl border border-base-content/10 bg-base-100">
                      <table class="table table-zebra table-sm">
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
                              <td>
                                <div class="flex items-center gap-2">
                                  <span class="font-mono text-xs sm:text-sm">{record.name}</span>
                                  <%= if record.managed do %>
                                    <span class="badge badge-outline badge-xs">managed</span>
                                  <% end %>
                                  <%= if Record.private?(record) do %>
                                    <span class="badge badge-primary badge-outline badge-xs">
                                      private
                                    </span>
                                  <% end %>
                                </div>
                              </td>
                              <td class="font-mono text-xs sm:text-sm">{record.type}</td>
                              <td class="font-mono text-xs break-all">{record_rdata(record)}</td>
                              <td class="font-mono text-xs">{record.ttl}</td>
                              <td>
                                <div class="flex gap-2">
                                  <%= if record.managed do %>
                                    <span class="text-xs text-base-content/60">
                                      managed elsewhere
                                    </span>
                                  <% else %>
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
                                  <% end %>
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
            </section>

            <section
              :if={
                @active_zone.status != "verified" and not builtin_zone?(@active_zone, @current_user)
              }
              class="card panel-card"
            >
              <div class="card-body p-0">
                <div class="border-b border-base-content/10 px-5 py-4">
                  <h3 class="text-sm font-semibold uppercase tracking-[0.16em] text-base-content/60">
                    Delegation
                  </h3>
                  <p class="mt-1 text-sm text-base-content/65">
                    If your registrar or current DNS host asks where to point the domain, publish these values there before checking setup.
                  </p>
                </div>
                <div class="space-y-4 p-5">
                  <div class="rounded-2xl border border-base-content/10 bg-base-200/20 px-4 py-4">
                    <p class="text-sm font-semibold">Elektrine nameservers</p>
                    <p class="mt-1 text-sm text-base-content/65">
                      Many registrars have a dedicated nameserver section. If they ask for nameservers, use these exactly:
                    </p>
                    <div class="mt-3 rounded-xl border border-base-content/10 bg-base-100 px-3 py-3 font-mono text-xs break-all text-base-content/80">
                      {Enum.join(@nameservers, ", ")}
                    </div>
                  </div>
                  <div class="overflow-x-auto">
                    <table class="table table-sm rounded-2xl border border-base-content/10">
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
                            <td class="font-mono text-xs">{record.type}</td>
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
            </section>
          </div>

          <section class="card panel-card">
            <div class="card-body p-0">
              <div class="border-b border-base-content/10 px-5 py-4">
                <h3 class="text-sm font-semibold uppercase tracking-[0.16em] text-base-content/60">
                  New record
                </h3>
                <p class="mt-1 text-sm text-base-content/65">
                  {record_help_text(@active_zone, @current_user)}
                </p>
              </div>
              <div class="p-5">
                <div class="mb-5">
                  <p class="text-sm font-semibold">I want to...</p>
                  <p class="mt-1 text-sm text-base-content/65">
                    Start from a common task and we will prefill the DNS record for you.
                  </p>
                  <div class="mt-3 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
                    <%= for preset <- record_preset_options(@active_zone) do %>
                      <button
                        type="button"
                        phx-click="record_preset"
                        phx-value-preset={preset.id}
                        class={record_preset_button_class(@selected_record_preset, preset.id)}
                      >
                        <span class="font-semibold">{preset.label}</span>
                        <span class="mt-1 block text-xs text-base-content/65">
                          {preset.description}
                        </span>
                      </button>
                    <% end %>
                  </div>
                </div>

                <div class="mb-5 grid gap-3 lg:grid-cols-2 2xl:grid-cols-4">
                  <button
                    type="button"
                    phx-click="record_type_preset"
                    phx-value-type="A"
                    class={record_type_preset_button_class(@record_form, "A")}
                  >
                    <p class="font-semibold">A / AAAA</p>
                    <p class="mt-1 text-base-content/65">
                      Point a name like `@` or `www` to an IP address.
                    </p>
                  </button>
                  <button
                    type="button"
                    phx-click="record_type_preset"
                    phx-value-type="CNAME"
                    class={record_type_preset_button_class(@record_form, "CNAME")}
                  >
                    <p class="font-semibold">CNAME</p>
                    <p class="mt-1 text-base-content/65">
                      Make one name follow another hostname, like `www` to `example.com`.
                    </p>
                  </button>
                  <button
                    type="button"
                    phx-click="record_type_preset"
                    phx-value-type="MX"
                    class={record_type_preset_button_class(@record_form, "MX")}
                  >
                    <p class="font-semibold">MX</p>
                    <p class="mt-1 text-base-content/65">
                      Tell other mail servers where email for this domain should go.
                    </p>
                  </button>
                  <button
                    type="button"
                    phx-click="record_type_preset"
                    phx-value-type="TXT"
                    class={record_type_preset_button_class(@record_form, "TXT")}
                  >
                    <p class="font-semibold">TXT</p>
                    <p class="mt-1 text-base-content/65">
                      Store verification tokens, SPF rules, or other text-based settings.
                    </p>
                  </button>
                </div>
                <.simple_form
                  for={@record_form}
                  bare={true}
                  phx-change="record_validate"
                  phx-submit="record_create"
                >
                  <div class="grid gap-x-4 gap-y-5 md:grid-cols-2 xl:grid-cols-1 2xl:grid-cols-2">
                    <.input
                      field={@record_form[:name]}
                      label="Name"
                      placeholder={record_name_placeholder(@active_zone, @current_user)}
                      required
                    />
                    <p class="text-xs text-base-content/55">
                      {record_name_field_help(@active_zone, @current_user)}
                    </p>
                    <.input
                      field={@record_form[:type]}
                      type="select"
                      label="Type"
                      options={Enum.map(@record_types, &{&1, &1})}
                    />
                    <p class="text-xs text-base-content/55">{record_type_help(@record_form)}</p>
                    <% value_spec = record_value_spec(@record_form) %>
                    <.input
                      field={@record_form[:content]}
                      label={value_spec.label}
                      placeholder={value_spec.placeholder}
                      required
                    />
                    <p class="text-xs text-base-content/55">{record_value_help(@record_form)}</p>
                    <.input field={@record_form[:ttl]} type="number" label="TTL" />
                    <p class="text-xs text-base-content/55">{ttl_help_text(@active_zone)}</p>
                    <.input
                      field={@record_form[:private]}
                      type="checkbox"
                      label="Private record"
                    />
                    <p class="text-xs text-base-content/55">
                      Only recursive/private DNS clients can resolve this record. Public authoritative queries will not receive it.
                    </p>
                    <%= for spec <- record_param_specs(@record_form) do %>
                      <.input
                        field={@record_form[spec.field]}
                        type={spec.type}
                        label={spec.label}
                        placeholder={spec.placeholder}
                      />
                    <% end %>
                  </div>
                  <:actions>
                    <.button>Add record</.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
          </section>

          <section :if={!builtin_zone?(@active_zone, @current_user)} class="card panel-card">
            <div class="card-body p-0">
              <div class="border-b border-base-content/10 px-5 py-4">
                <h3 class="text-sm font-semibold uppercase tracking-[0.16em] text-base-content/60">
                  Linked domains
                </h3>
                <p class="mt-1 text-sm text-base-content/65">
                  Shows whether this zone is already referenced by profile or email custom domain settings.
                </p>
              </div>
              <div class="space-y-3 p-5">
                <%= if @linked_domains == [] do %>
                  <p class="text-sm text-base-content/60">
                    No linked profile or email custom domains match this zone.
                  </p>
                <% else %>
                  <%= for linked_domain <- @linked_domains do %>
                    <div class="rounded-2xl border border-base-content/10 bg-base-200/20 p-4">
                      <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                        <div class="space-y-2">
                          <div class="flex flex-wrap items-center gap-2">
                            <p class="font-semibold">{linked_domain.title}</p>
                            <span class="badge badge-outline">{linked_domain.kind_label}</span>
                            <span class={linked_domain_status_badge_class(linked_domain.status)}>
                              {linked_domain.status}
                            </span>
                          </div>
                          <p class="text-sm text-base-content/65">{linked_domain.summary}</p>
                          <%= if linked_domain.last_error do %>
                            <p class="text-sm text-warning">{linked_domain.last_error}</p>
                          <% end %>
                        </div>
                        <div class="flex flex-wrap items-center gap-3 lg:justify-end">
                          <div class="text-sm text-base-content/60">
                            {Enum.count(linked_domain.checks, &(&1.status == "ok"))}/{length(
                              linked_domain.checks
                            )} checks matched
                          </div>
                          <button
                            :if={
                              Enum.any?(
                                linked_domain.checks,
                                &(&1.status == "missing" and &1.addable)
                              )
                            }
                            type="button"
                            phx-click="linked_domain_apply"
                            phx-value-kind={linked_domain.kind}
                            phx-value-domain={linked_domain.domain}
                            class="btn btn-sm btn-outline"
                          >
                            Add missing records
                          </button>
                        </div>
                      </div>
                      <div class="mt-4 grid gap-2 text-sm">
                        <%= for check <- linked_domain.checks do %>
                          <div class="rounded-xl border border-base-content/10 bg-base-100 px-3 py-2">
                            <div class="flex items-center justify-between gap-3">
                              <span>{check.label}</span>
                              <span class={linked_domain_check_badge_class(check.status)}>
                                {check.status}
                              </span>
                            </div>
                            <p class="mt-1 break-all text-xs text-base-content/60">
                              {check.detail}
                            </p>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
          </section>

          <section :if={!builtin_zone?(@active_zone, @current_user)} class="card panel-card">
            <div class="card-body p-0">
              <div class="border-b border-base-content/10 px-5 py-4">
                <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                  <div>
                    <h3 class="text-sm font-semibold uppercase tracking-[0.16em] text-base-content/60">
                      Domain health
                    </h3>
                    <p class="mt-1 text-sm text-base-content/65">
                      Checks DNS, mail security, TLS posture, deliverability signals, and suggested fixes.
                    </p>
                  </div>
                  <div class="flex items-center gap-3">
                    <div
                      class="radial-progress text-primary"
                      style={"--value:#{@domain_health.score}; --size:4rem; --thickness:0.4rem;"}
                    >
                      <span class="text-sm font-semibold">{@domain_health.score}</span>
                    </div>
                    <div class="text-sm">
                      <span class={domain_health_badge_class(@domain_health.status)}>
                        {@domain_health.status}
                      </span>
                      <p class="mt-1 text-xs text-base-content/60">{@domain_health.summary}</p>
                    </div>
                  </div>
                </div>
              </div>
              <div class="space-y-4 p-5">
                <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
                  <%= for check <- @domain_health.checks do %>
                    <div class="rounded-2xl border border-base-content/10 bg-base-200/20 p-4">
                      <div class="flex items-start justify-between gap-3">
                        <div>
                          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
                            {domain_health_category_label(check.category)}
                          </p>
                          <p class="mt-1 font-semibold">{check.label}</p>
                        </div>
                        <span class={domain_health_badge_class(check.status)}>{check.status}</span>
                      </div>
                      <p class="mt-3 text-sm text-base-content/65">{check.detail}</p>
                      <%= if check.fix do %>
                        <p class="mt-3 rounded-xl bg-base-100 px-3 py-2 text-xs text-base-content/60">
                          {check.fix}
                        </p>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          </section>

          <section :if={!builtin_zone?(@active_zone, @current_user)} class="card panel-card">
            <div class="card-body p-0">
              <div class="border-b border-base-content/10 px-5 py-4">
                <h3 class="text-sm font-semibold uppercase tracking-[0.16em] text-base-content/60">
                  Service templates
                </h3>
                <p class="mt-1 text-sm text-base-content/65">
                  Prebuilt setup recipes for common jobs like websites, email, and app hostnames.
                </p>
              </div>
              <div class="space-y-3 p-5">
                <%= for health <- @service_health do %>
                  <div class="rounded-2xl border border-base-content/10 bg-base-200/20 p-4">
                    <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                      <div class="min-w-0 xl:w-72">
                        <div class="flex items-center gap-2">
                          <p class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
                            {service_label(health.service)}
                          </p>
                          <span class={service_badge_class(health.status)}>{health.status}</span>
                        </div>
                        <p class="mt-1 text-sm text-base-content/65">
                          {service_summary(health.service)}
                        </p>
                        <p class="mt-2 text-xs text-base-content/55">
                          {service_hint(health.service)}
                        </p>
                        <div class="mt-3 flex flex-wrap gap-2 text-xs text-base-content/60">
                          <span>{length(health.managed_records)} record(s)</span>
                          <span>
                            {Enum.count(health.checks, &(&1.status == "ok"))}/{length(health.checks)} healthy
                          </span>
                        </div>
                      </div>

                      <div class="min-w-0 flex-1 space-y-3">
                        <%= if health.last_error do %>
                          <div class="alert alert-warning px-3 py-2 text-sm">
                            {health.last_error}
                          </div>
                        <% end %>

                        <%= if health.checks != [] do %>
                          <div class="grid gap-2 text-sm md:grid-cols-2">
                            <%= for check <- health.checks do %>
                              <div class="flex items-center justify-between gap-3 rounded-xl border border-base-content/10 bg-base-100 px-3 py-2">
                                <span>{check.label}</span>
                                <span class={check_badge_class(check.status)}>
                                  {check.status}
                                </span>
                              </div>
                            <% end %>
                          </div>
                        <% end %>

                        <.simple_form
                          for={Map.fetch!(@service_forms, health.service)}
                          bare={true}
                          phx-submit="service_apply"
                          class="border-t border-base-content/10 pt-4"
                        >
                          <input type="hidden" name="service" value={health.service} />
                          <%= if health.service == "mail" do %>
                            <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:mail_target]}
                                label="MX target"
                              />
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:dmarc_policy]}
                                type="select"
                                label="DMARC policy"
                                options={[
                                  {"quarantine", "quarantine"},
                                  {"reject", "reject"},
                                  {"none", "none"}
                                ]}
                              />
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:mta_sts_mode]}
                                type="select"
                                label="MTA-STS mode"
                                options={[
                                  {"enforce", "enforce"},
                                  {"testing", "testing"},
                                  {"none", "none"}
                                ]}
                              />
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:tls_rpt_rua]}
                                label="TLS-RPT rua"
                                placeholder={"mailto:postmaster@" <> @active_zone.domain}
                              />
                            </div>
                          <% end %>
                          <%= if health.service == "web" do %>
                            <div class="grid gap-4 md:grid-cols-2">
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:www_target]}
                                label="WWW target"
                              />
                            </div>
                          <% end %>
                          <%= if health.service == "turn" do %>
                            <div class="grid gap-4 md:grid-cols-2">
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:turn_host]}
                                label="TURN host"
                                placeholder="turn"
                              />
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:turn_target]}
                                label="TURN target"
                                placeholder={@active_zone.domain}
                              />
                            </div>
                          <% end %>
                          <%= if health.service == "vpn" do %>
                            <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:vpn_host]}
                                label="VPN host"
                                placeholder="vpn"
                              />
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:vpn_target]}
                                label="VPN target"
                                placeholder={@active_zone.domain}
                              />
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:vpn_api_host]}
                                label="Admin/API host"
                                placeholder="vpn-api"
                              />
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:vpn_api_target]}
                                label="Admin/API target"
                                placeholder={@active_zone.domain}
                              />
                            </div>
                          <% end %>
                          <%= if health.service == "bluesky" do %>
                            <div class="grid gap-4 md:grid-cols-2">
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:bluesky_host]}
                                label="Bluesky host"
                                placeholder="bsky"
                              />
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:bluesky_target]}
                                label="Bluesky target"
                                placeholder={@active_zone.domain}
                              />
                            </div>
                          <% end %>
                          <:actions>
                            <.button>Apply / Repair</.button>
                          </:actions>
                        </.simple_form>

                        <%= if health.enabled do %>
                          <div class="pt-1">
                            <button
                              type="button"
                              phx-click="service_disable"
                              phx-value-service={health.service}
                              class="link link-hover text-sm text-base-content/65"
                            >
                              Disable service
                            </button>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </section>
        </main>
      </div>
    </div>
    """
  end

  defp params_with_user(socket, params),
    do: Map.put(params, "user_id", socket.assigns.current_user.id)

  defp builtin_zone?(%Zone{} = zone, user), do: DNS.builtin_user_zone?(zone, user)
  defp builtin_zone?(_, _), do: false

  defp builtin_zone_hosted_by_platform?(user),
    do: User.built_in_subdomain_hosted_by_platform?(user)

  defp builtin_zone_mode_label(user) do
    if builtin_zone_hosted_by_platform?(user), do: "platform-hosted", else: "dns-managed"
  end

  defp builtin_zone_mode_button_class(user, mode) do
    active? = User.built_in_subdomain_mode(user) == mode

    [
      "join-item btn btn-sm",
      if(active?, do: "btn-primary", else: "btn-outline")
    ]
  end

  defp zone_role_label(%Zone{} = zone, user) do
    cond do
      builtin_zone?(zone, user) and builtin_zone_hosted_by_platform?(user) -> "built-in host"
      builtin_zone?(zone, user) -> "built-in, dns-managed"
      true -> "delegated zone"
    end
  end

  defp zone_role_label(_, _), do: "zone"

  defp zone_description(%Zone{} = zone, user) do
    cond do
      builtin_zone?(zone, user) and builtin_zone_hosted_by_platform?(user) ->
        "Built-in Elektrine subdomain with platform-managed apex routing."

      builtin_zone?(zone, user) ->
        "Built-in Elektrine subdomain with user-managed DNS."

      true ->
        "Authoritative DNS zone delegated to Elektrine."
    end
  end

  defp zone_description(_, _), do: "DNS zone"

  defp record_name_placeholder(%Zone{} = zone, user) do
    cond do
      builtin_zone?(zone, user) and builtin_zone_hosted_by_platform?(user) ->
        "blog or _acme-challenge"

      builtin_zone?(zone, user) ->
        "@ or blog"

      true ->
        "@ or www"
    end
  end

  defp record_name_placeholder(_, _), do: "@ or www"

  defp record_help_text(%Zone{} = zone, user) do
    cond do
      builtin_zone?(zone, user) and builtin_zone_hosted_by_platform?(user) ->
        "Use `@` for the zone apex. While platform-hosted, apex is limited to `TXT` and `CAA`; use labels like `blog`, `vpn`, or `_acme-challenge` for other records."

      builtin_zone?(zone, user) ->
        "Use `@` for the zone apex or any relative label such as `www`, `mail`, or `blog`."

      true ->
        "Use `@` for the zone apex or any relative label such as `www`, `mail`, or `vpn`."
    end
  end

  defp record_help_text(_, _), do: "Use `@` for the apex of the selected zone."

  defp record_name_field_help(%Zone{} = zone, user) do
    if builtin_zone?(zone, user) and builtin_zone_hosted_by_platform?(user) do
      "`@` means the main domain. Use labels like `blog`, `mail`, or `_acme-challenge` for subdomains and verification records."
    else
      "`@` means the main domain itself. `www` becomes `www.#{zone.domain}` and `mail` becomes `mail.#{zone.domain}`."
    end
  end

  defp record_name_field_help(_, _), do: "`@` means the main domain itself."

  defp record_type_help(form) do
    case record_form_type(form) do
      "A" ->
        "Points a name to an IPv4 address, such as `198.51.100.42`."

      "AAAA" ->
        "Points a name to an IPv6 address."

      "ALIAS" ->
        "Flattens an apex hostname to another hostname, similar to a root-safe CNAME."

      "CAA" ->
        "Limits which certificate authorities may issue TLS certificates for this name."

      "CNAME" ->
        "Makes one hostname follow another hostname. Good for aliases like `www`."

      "HTTPS" ->
        "Publishes HTTPS endpoint hints like ALPN, port, ECH, or address hints."

      "MX" ->
        "Sends email for this domain to a mail server. Lower priority numbers win first."

      "TXT" ->
        "Stores text, often used for SPF, DKIM, DMARC, or ownership verification."

      "NS" ->
        "Delegates a name to another nameserver. Usually only needed for advanced setups."

      "SRV" ->
        "Advertises a service target with priority, weight, and port information."

      "SSHFP" ->
        "Publishes SSH host key fingerprints for SSH clients that verify host keys with DNSSEC."

      "SVCB" ->
        "Publishes generic service binding information, often used for modern service discovery."

      "TLSA" ->
        "Publishes DANE certificate association data for a host and port."

      other ->
        "Creates a #{other} record for a more specialized DNS use case."
    end
  end

  defp record_value_help(form) do
    case record_form_type(form) do
      "A" ->
        "Enter the destination IPv4 address."

      "AAAA" ->
        "Enter the destination IPv6 address."

      "ALIAS" ->
        "Enter the hostname this apex record should flatten to."

      "CAA" ->
        "Enter the certificate authority value, such as `letsencrypt.org`."

      "CNAME" ->
        "Enter the hostname this should point to, not an IP address."

      "HTTPS" ->
        "Enter the target hostname followed by optional params like `alpn=h2,h3` or `port=443`."

      "MX" ->
        "Enter the mail server hostname here, then set its priority below."

      "TXT" ->
        "Paste the full text exactly as given by your provider."

      "NS" ->
        "Enter the authoritative nameserver hostname."

      "SSHFP" ->
        "Enter the SSH public host key fingerprint as hexadecimal data."

      "SVCB" ->
        "Enter the target hostname followed by optional service parameters."

      "TLSA" ->
        "Enter the certificate association data as hexadecimal."

      _ ->
        "Enter the value exactly as required by the service you are connecting."
    end
  end

  defp ttl_help_text(%Zone{} = zone) do
    "How long DNS caches this record. Leave it near the zone default (#{zone.default_ttl}) unless a provider tells you otherwise."
  end

  defp ttl_help_text(_), do: "How long DNS caches this record before checking again."

  defp zone_scan_for_params(params) when is_map(params) do
    case Map.get(params, "domain") do
      value when is_binary(value) -> DNS.scan_existing_zone(value)
      _ -> nil
    end
  end

  defp zone_scan_for_params(_), do: nil

  defp keep_matching_scan(nil, _params), do: nil

  defp keep_matching_scan(scan, params) when is_map(params) do
    case Map.get(params, "domain") do
      value when is_binary(value) ->
        if normalize_dns_name(value) == normalize_dns_name(scan.domain), do: scan, else: nil

      _ ->
        nil
    end
  end

  defp keep_matching_scan(_, _), do: nil

  defp zone_form_attrs(%Phoenix.HTML.Form{source: changeset}) do
    %{
      "domain" => Ecto.Changeset.get_field(changeset, :domain),
      "default_ttl" => Ecto.Changeset.get_field(changeset, :default_ttl)
    }
  end

  defp zone_form_attrs(_), do: %{}

  defp format_scan_values([]), do: "none found"
  defp format_scan_values(values) when is_list(values), do: Enum.join(values, ", ")
  defp format_scan_values(value), do: to_string(value)

  defp matching_scan_zone(zones, %{domain: domain}) when is_list(zones) do
    expected = normalize_dns_name(domain)
    Enum.find(zones, &(normalize_dns_name(&1.domain) == expected))
  end

  defp matching_scan_zone(_, _), do: nil

  defp import_scan_records(%Zone{} = zone, scan, selected_ids) do
    selected = MapSet.new(List.wrap(selected_ids))

    scan
    |> scan_import_items()
    |> Enum.filter(&MapSet.member?(selected, &1.id))
    |> Enum.reduce(%{imported: 0, skipped: 0}, fn item, counts ->
      case DNS.create_record(zone, item.attrs) do
        {:ok, _} -> %{counts | imported: counts.imported + 1}
        {:error, _} -> %{counts | skipped: counts.skipped + 1}
      end
    end)
  end

  defp import_scan_records(_, _, _), do: %{imported: 0, skipped: 0}

  defp scan_import_items(%{records: records}) when is_list(records) do
    records
    |> Enum.flat_map(&scan_record_items/1)
    |> Enum.with_index()
    |> Enum.map(fn {item, index} -> Map.put(item, :id, Integer.to_string(index)) end)
  end

  defp scan_import_items(_), do: []

  defp scan_record_items(%{host: host, type: type, values: values}) when is_list(values) do
    Enum.map(values, &scan_record_item(host, type, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp scan_record_items(_), do: []

  defp scan_record_item(host, "MX", value) when is_binary(value) do
    case String.split(value, ~r/\s+/, parts: 2, trim: true) do
      [priority, target] ->
        case Integer.parse(priority) do
          {priority, ""} ->
            %{
              host: host,
              type: "MX",
              value: value,
              attrs: %{
                "name" => host,
                "type" => "MX",
                "content" => target,
                "priority" => priority
              }
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp scan_record_item(host, type, value) when is_binary(value) do
    %{
      host: host,
      type: type,
      value: value,
      attrs: %{"name" => host, "type" => type, "content" => value}
    }
  end

  defp scan_record_item(_, _, _), do: nil

  defp scan_import_message(%{imported: imported, skipped: skipped}, created_zone?) do
    prefix = if(created_zone?, do: "Zone created.", else: "Records imported.")

    "#{prefix} Added #{imported} record#{if imported == 1, do: "", else: "s"}.#{scan_import_skipped_message(skipped)}"
  end

  defp scan_import_skipped_message(0), do: ""

  defp scan_import_skipped_message(skipped) do
    " Skipped #{skipped} duplicate or invalid record#{if skipped == 1, do: "", else: "s"}."
  end

  defp format_user_error(changeset), do: format_zone_error(changeset)

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

  defp record_form(%Zone{id: zone_id}, attrs) when is_map(attrs),
    do: to_form(DNS.change_record(%Record{}, Map.put(attrs, "zone_id", zone_id)), as: :record)

  defp zone_settings_form(nil), do: nil

  defp zone_settings_form(%Zone{} = zone),
    do: to_form(DNS.change_zone(zone, %{"force_https" => zone.force_https}), as: :zone)

  defp service_forms(nil) do
    %{
      "mail" =>
        to_form(
          %{
            "mail_target" => "",
            "dmarc_policy" => "quarantine",
            "mta_sts_mode" => "enforce",
            "tls_rpt_rua" => ""
          },
          as: :service_config
        ),
      "web" => to_form(%{"www_target" => ""}, as: :service_config),
      "turn" => to_form(%{"turn_host" => "turn", "turn_target" => ""}, as: :service_config),
      "vpn" =>
        to_form(
          %{
            "vpn_host" => "vpn",
            "vpn_target" => "",
            "vpn_api_host" => "",
            "vpn_api_target" => ""
          },
          as: :service_config
        ),
      "bluesky" =>
        to_form(%{"bluesky_host" => "bsky", "bluesky_target" => ""}, as: :service_config)
    }
  end

  defp service_forms(%Zone{} = zone) do
    health = DNS.zone_service_health(zone)

    %{
      "mail" =>
        service_form_from_health(
          Enum.find(health, &(&1.service == "mail")),
          %{
            "mail_target" => MailSecurity.default_mail_target(zone),
            "dmarc_policy" => "quarantine",
            "mta_sts_mode" => "enforce",
            "tls_rpt_rua" => "mailto:postmaster@#{zone.domain}"
          }
        ),
      "web" =>
        service_form_from_health(
          Enum.find(health, &(&1.service == "web")),
          %{"www_target" => zone.domain}
        ),
      "turn" =>
        service_form_from_health(
          Enum.find(health, &(&1.service == "turn")),
          %{"turn_host" => "turn", "turn_target" => zone.domain}
        ),
      "vpn" =>
        service_form_from_health(
          Enum.find(health, &(&1.service == "vpn")),
          %{
            "vpn_host" => "vpn",
            "vpn_target" => zone.domain,
            "vpn_api_host" => "",
            "vpn_api_target" => zone.domain
          }
        ),
      "bluesky" =>
        service_form_from_health(
          Enum.find(health, &(&1.service == "bluesky")),
          %{"bluesky_host" => "bsky", "bluesky_target" => zone.domain}
        )
    }
  end

  defp service_health(nil),
    do: Enum.map(["mail", "web", "turn", "vpn", "bluesky"], &blank_service_health/1)

  defp service_health(%Zone{} = zone) do
    health = DNS.zone_service_health(zone)
    Enum.map(["mail", "web", "turn", "vpn", "bluesky"], &service_entry(health, &1))
  end

  defp save_record(zone, nil, params), do: DNS.create_record(zone, params)

  defp save_record(zone, record_id, params) do
    case DNS.get_record(record_id, zone.id) do
      %Record{} = record ->
        DNS.update_record(record, params)

      _ ->
        {:error, DNS.change_record(%Record{}, params) |> Map.put(:action, :insert)}
    end
  end

  defp compact_zone_link_class(zone, active_zone) do
    active? = active_zone && zone.id == active_zone.id

    [
      "grid grid-cols-[minmax(0,1fr)_112px_44px] items-center gap-3 border-b border-base-300 px-5 py-3 transition",
      if(active?,
        do: "bg-primary/8",
        else: "hover:bg-base-200/40"
      )
    ]
  end

  defp service_entry(health, service) do
    Enum.find(health, blank_service_health(service), &(&1.service == service))
  end

  defp linked_domains(nil, _user_id), do: []

  defp linked_domains(%Zone{} = zone, user_id) when is_integer(user_id) do
    zone_domain = normalize_dns_name(zone.domain)

    profile_domains =
      user_id
      |> ProfileCustomDomains.list_user_custom_domains()
      |> Enum.filter(&(normalize_dns_name(&1.domain) == zone_domain))
      |> Enum.map(&linked_domain_entry(&1, :profile, zone))

    email_domains =
      user_id
      |> list_email_custom_domains()
      |> Enum.filter(&(normalize_dns_name(&1.domain) == zone_domain))
      |> Enum.map(&linked_domain_entry(&1, :email, zone))

    profile_domains ++ email_domains
  end

  defp linked_domains(_, _user_id), do: []

  defp linked_domain_entry(custom_domain, :profile, zone) do
    checks =
      custom_domain
      |> ProfileCustomDomains.dns_records_for_custom_domain()
      |> Enum.map(&linked_domain_check(zone, &1))

    %{
      domain: custom_domain.domain,
      kind: "profile",
      title: custom_domain.domain,
      kind_label: "Profile",
      status: custom_domain.status || "pending",
      summary: "Profile custom domain configured in account settings.",
      last_error: custom_domain.last_error,
      checks: checks
    }
  end

  defp linked_domain_entry(custom_domain, :email, zone) do
    checks =
      custom_domain
      |> email_custom_domain_records()
      |> Enum.map(&linked_domain_check(zone, &1))

    %{
      domain: custom_domain.domain,
      kind: "email",
      title: custom_domain.domain,
      kind_label: "Email",
      status: custom_domain.status || "pending",
      summary: "Custom email domain configured in account settings.",
      last_error: custom_domain.last_error || custom_domain.dkim_last_error,
      checks: checks
    }
  end

  defp linked_domain_check(zone, %{type: "ALIAS", host: host, value: value, label: label}) do
    if normalize_dns_name(host) == normalize_dns_name(zone.domain) do
      %{
        label: label,
        status:
          if(record_exists_for_expected?(zone, %{type: "ALIAS", host: host, value: value}),
            do: "ok",
            else: "missing"
          ),
        addable: true,
        detail:
          linked_domain_check_detail(%{type: "ALIAS", host: host, value: value, label: label})
      }
    else
      linked_domain_check(zone, %{type: "CNAME", host: host, value: value, label: label})
    end
  end

  defp linked_domain_check(zone, expected_record) do
    matching_record =
      Enum.find(zone.records || [], &record_matches_expected?(&1, expected_record, zone))

    %{
      label: expected_record.label,
      status: if(matching_record, do: "ok", else: "missing"),
      addable: true,
      detail: linked_domain_check_detail(expected_record)
    }
  end

  defp load_linked_custom_domain("profile", domain, user_id) do
    case Enum.find(ProfileCustomDomains.list_user_custom_domains(user_id), &(&1.domain == domain)) do
      nil -> :error
      custom_domain -> {:ok, custom_domain, :profile}
    end
  end

  defp load_linked_custom_domain("email", domain, user_id) do
    case Enum.find(list_email_custom_domains(user_id), &(&1.domain == domain)) do
      nil -> :error
      custom_domain -> {:ok, custom_domain, :email}
    end
  end

  defp load_linked_custom_domain(_, _, _), do: :error

  defp expected_linked_domain_records(custom_domain, :profile),
    do: ProfileCustomDomains.dns_records_for_custom_domain(custom_domain)

  defp expected_linked_domain_records(custom_domain, :email),
    do: email_custom_domain_records(custom_domain)

  defp list_email_custom_domains(user_id) do
    module = Module.concat([Elektrine, Email, CustomDomains])

    if Code.ensure_loaded?(module) and function_exported?(module, :list_user_custom_domains, 1) do
      module.list_user_custom_domains(user_id)
    else
      []
    end
  end

  defp email_custom_domain_records(custom_domain) do
    module = Module.concat([Elektrine, Email, CustomDomains])

    if Code.ensure_loaded?(module) and
         function_exported?(module, :dns_records_for_custom_domain, 1) do
      module.dns_records_for_custom_domain(custom_domain)
    else
      []
    end
  end

  defp record_exists_for_expected?(%Zone{} = zone, expected_record) do
    Enum.any?(zone.records || [], &record_matches_expected?(&1, expected_record, zone))
  end

  defp expected_record_to_attrs(%Zone{} = zone, expected_record) do
    priority = Map.get(expected_record, :priority)

    attrs = %{
      "name" => expected_record_name(zone, expected_record.host),
      "type" => normalize_expected_type(expected_record.type),
      "content" => expected_record.value,
      "ttl" => zone.default_ttl
    }

    case priority do
      nil -> attrs
      priority -> Map.put(attrs, "priority", priority)
    end
  end

  defp expected_record_name(%Zone{} = zone, host) do
    zone_domain = normalize_dns_name(zone.domain)
    normalized_host = normalize_dns_name(host)

    cond do
      normalized_host == zone_domain ->
        "@"

      String.ends_with?(normalized_host, "." <> zone_domain) ->
        String.trim_trailing(normalized_host, "." <> zone_domain)

      true ->
        normalized_host
    end
  end

  defp normalize_expected_type(type), do: type

  defp record_matches_expected?(record, expected_record, zone) do
    record_host = record_host(zone, record)
    expected_host = normalize_dns_name(expected_record.host)
    record_type = normalize_dns_name(record.type)
    expected_type = normalize_dns_name(expected_record.type)

    record_host == expected_host and
      record_type == expected_type and
      record_value_matches?(record, expected_record)
  end

  defp record_value_matches?(
         %Record{type: "MX", content: content, priority: priority},
         expected_record
       ) do
    expected_priority = Map.get(expected_record, :priority)

    normalize_dns_name(content) == normalize_dns_name(expected_record.value) and
      (is_nil(expected_priority) or priority == expected_priority)
  end

  defp record_value_matches?(%Record{type: type, content: content}, expected_record)
       when type in ["ALIAS", "CNAME", "NS"] do
    normalize_dns_name(content) == normalize_dns_name(expected_record.value)
  end

  defp record_value_matches?(%Record{content: content}, expected_record) do
    normalize_record_value(content) == normalize_record_value(expected_record.value)
  end

  defp record_host(%Zone{} = zone, %Record{name: name}) do
    zone_domain = normalize_dns_name(zone.domain)

    case normalize_dns_name(name) do
      "@" ->
        zone_domain

      record_name ->
        if String.ends_with?(record_name, "." <> zone_domain) do
          record_name
        else
          normalize_dns_name(record_name <> "." <> zone.domain)
        end
    end
  end

  defp linked_domain_check_detail(expected_record) do
    base = "#{expected_record.type} #{expected_record.host} -> #{expected_record.value}"
    priority = Map.get(expected_record, :priority)

    if is_nil(priority) do
      base
    else
      base <> " (priority #{priority})"
    end
  end

  defp normalize_record_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp normalize_record_value(value), do: value |> to_string() |> normalize_record_value()

  defp normalize_dns_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp normalize_dns_name(value), do: value |> to_string() |> normalize_dns_name()

  defp blank_service_health(service) do
    %{
      service: service,
      enabled: false,
      mode: nil,
      status: "not_configured",
      last_error: nil,
      managed_records: []
    }
  end

  defp service_summary("mail"),
    do: "Sets up the usual DNS records needed to receive and protect email on your domain."

  defp service_summary("web"),
    do: "Creates the common hostname records used for a website, including `www`."

  defp service_summary("turn"),
    do: "Creates a TURN hostname for voice, video, or WebRTC relay setups."

  defp service_summary("vpn"),
    do: "Creates a VPN hostname and optional admin/API hostname for remote access setups."

  defp service_summary("bluesky"),
    do: "Creates the hostname Bluesky expects for a managed PDS or handle setup."

  defp service_summary(_), do: "Managed DNS setup recipe."

  defp service_label("mail"), do: "Email"
  defp service_label("web"), do: "Website"
  defp service_label("turn"), do: "TURN / Calls"
  defp service_label("vpn"), do: "VPN"
  defp service_label("bluesky"), do: "Bluesky"
  defp service_label(service), do: String.capitalize(service)

  defp service_hint("mail"),
    do: "Good starting point when you want this domain to send and receive email."

  defp service_hint("web"),
    do: "Use this when you want `www` and related website hostnames pointed for you."

  defp service_hint("turn"),
    do: "Useful for chat, calling, or conferencing products that need a TURN relay hostname."

  defp service_hint("vpn"),
    do: "Useful when you run a VPN gateway and want a memorable hostname like `vpn.example.com`."

  defp service_hint("bluesky"),
    do: "Useful if you are hosting your own Bluesky PDS or related handle infrastructure."

  defp service_hint(_), do: "Managed DNS recipe for a common setup."

  defp record_preset_options(%Zone{} = zone) do
    [
      %{
        id: "website",
        label: "Point website",
        description: "Point the main domain at a web server IP address.",
        attrs: %{
          "name" => "@",
          "type" => "A",
          "content" => "198.51.100.42",
          "ttl" => zone.default_ttl
        }
      },
      %{
        id: "email",
        label: "Set up email",
        description: "Create an MX record so mail for this domain goes to your mail host.",
        attrs: %{
          "name" => "@",
          "type" => "MX",
          "content" => "mail.#{zone.domain}",
          "priority" => 10,
          "ttl" => zone.default_ttl
        }
      },
      %{
        id: "verification",
        label: "Verify domain ownership",
        description: "Add the TXT record many services use to prove you control the domain.",
        attrs: %{
          "name" => "@",
          "type" => "TXT",
          "content" => "paste-verification-token-here",
          "ttl" => zone.default_ttl
        }
      },
      %{
        id: "subdomain",
        label: "Add subdomain",
        description: "Create a subdomain like `blog` or `app` and point it somewhere.",
        attrs: %{
          "name" => "blog",
          "type" => "CNAME",
          "content" => zone.domain,
          "ttl" => zone.default_ttl
        }
      }
    ]
  end

  defp record_preset_options(_), do: []

  defp record_preset_attrs(%Zone{} = zone, preset) do
    zone
    |> record_preset_options()
    |> Enum.find(%{}, &(&1.id == preset))
    |> case do
      %{attrs: attrs} -> attrs
      _ -> %{}
    end
  end

  defp record_preset_button_class(selected_preset, preset_id) do
    [
      "rounded-2xl border px-4 py-3 text-left text-sm transition",
      if(selected_preset == preset_id,
        do: "border-primary bg-primary/8",
        else: "border-base-content/10 bg-base-200/20 hover:bg-base-200/35"
      )
    ]
  end

  defp record_type_preset_button_class(form, preset_type) do
    selected_type = record_form_type(form)

    active? =
      case preset_type do
        "A" -> selected_type in ["A", "AAAA"]
        _ -> selected_type == preset_type
      end

    [
      "rounded-2xl border px-4 py-3 text-left text-sm transition",
      if(active?,
        do: "border-primary bg-primary/8",
        else: "border-base-content/10 bg-base-200/20 hover:bg-base-200/35"
      )
    ]
  end

  defp record_type_preset_attrs(%Zone{} = zone, "A") do
    %{"name" => "@", "type" => "A", "content" => "198.51.100.42", "ttl" => zone.default_ttl}
  end

  defp record_type_preset_attrs(%Zone{} = zone, "CNAME") do
    %{"name" => "www", "type" => "CNAME", "content" => zone.domain, "ttl" => zone.default_ttl}
  end

  defp record_type_preset_attrs(%Zone{} = zone, "MX") do
    %{
      "name" => "@",
      "type" => "MX",
      "content" => "mail.#{zone.domain}",
      "priority" => 10,
      "ttl" => zone.default_ttl
    }
  end

  defp record_type_preset_attrs(%Zone{} = zone, "TXT") do
    %{
      "name" => "@",
      "type" => "TXT",
      "content" => "paste-text-value-here",
      "ttl" => zone.default_ttl
    }
  end

  defp record_type_preset_attrs(%Zone{} = zone, _type) do
    %{"name" => "@", "type" => "A", "content" => "198.51.100.42", "ttl" => zone.default_ttl}
  end

  defp record_value_spec(form) do
    case record_form_type(form) do
      "DNSKEY" ->
        %{label: "Public key", placeholder: "AwEAAc..."}

      "DS" ->
        %{label: "Digest", placeholder: "2BB183AF5F22588179A53B0A98631FAD1A292118"}

      "HTTPS" ->
        %{label: "Target and parameters", placeholder: ". alpn=h2,h3 port=443"}

      "SSHFP" ->
        %{label: "Fingerprint", placeholder: "1234567890ABCDEF1234567890ABCDEF"}

      "SVCB" ->
        %{label: "Target and parameters", placeholder: "svc.example.net alpn=h2 port=8443"}

      "TLSA" ->
        %{label: "Certificate data", placeholder: "A1B2C3D4..."}

      "TXT" ->
        %{label: "Text value", placeholder: "v=spf1 mx ~all"}

      _ ->
        %{label: "Value", placeholder: "198.51.100.42"}
    end
  end

  defp record_param_specs(form) do
    case record_form_type(form) do
      "MX" ->
        [%{field: :priority, label: "Priority", placeholder: "10", type: "number"}]

      "SRV" ->
        [
          %{field: :priority, label: "Priority", placeholder: "10", type: "number"},
          %{field: :weight, label: "Weight", placeholder: "5", type: "number"},
          %{field: :port, label: "Port", placeholder: "443", type: "number"}
        ]

      "CAA" ->
        [
          %{field: :flags, label: "Flags", placeholder: "0", type: "number"},
          %{field: :tag, label: "Tag", placeholder: "issue", type: "text"}
        ]

      "DNSKEY" ->
        [
          %{field: :flags, label: "Flags", placeholder: "257", type: "number"},
          %{field: :protocol, label: "Protocol", placeholder: "3", type: "number"},
          %{field: :algorithm, label: "Algorithm", placeholder: "13", type: "number"}
        ]

      "DS" ->
        [
          %{field: :key_tag, label: "Key tag", placeholder: "12345", type: "number"},
          %{field: :algorithm, label: "Algorithm", placeholder: "13", type: "number"},
          %{field: :digest_type, label: "Digest type", placeholder: "2", type: "number"}
        ]

      "TLSA" ->
        [
          %{field: :usage, label: "Usage", placeholder: "3", type: "number"},
          %{field: :selector, label: "Selector", placeholder: "1", type: "number"},
          %{field: :matching_type, label: "Matching type", placeholder: "1", type: "number"}
        ]

      "SSHFP" ->
        [
          %{field: :algorithm, label: "Algorithm", placeholder: "4", type: "number"},
          %{field: :digest_type, label: "Fingerprint type", placeholder: "2", type: "number"}
        ]

      type when type in ["HTTPS", "SVCB"] ->
        [%{field: :priority, label: "Priority", placeholder: "1", type: "number"}]

      _ ->
        []
    end
  end

  defp record_form_type(form) do
    form
    |> Phoenix.HTML.Form.input_value(:type)
    |> case do
      nil -> "A"
      value -> value |> to_string() |> String.upcase()
    end
  end

  defp record_rdata(%{type: "MX", priority: priority, content: content}),
    do: "#{priority || 10} #{content}"

  defp record_rdata(%{
         type: "SRV",
         priority: priority,
         weight: weight,
         port: port,
         content: content
       }),
       do: "#{priority || 0} #{weight || 0} #{port || 0} #{content}"

  defp record_rdata(%{type: "CAA", flags: flags, tag: tag, content: content}),
    do: "#{flags || 0} #{tag || "issue"} #{content}"

  defp record_rdata(%{
         type: "DNSKEY",
         flags: flags,
         protocol: protocol,
         algorithm: algorithm,
         content: content
       }),
       do: "#{flags || 0} #{protocol || 3} #{algorithm || 0} #{content}"

  defp record_rdata(%{
         type: "DS",
         key_tag: key_tag,
         algorithm: algorithm,
         digest_type: digest_type,
         content: content
       }),
       do: "#{key_tag || 0} #{algorithm || 0} #{digest_type || 0} #{content}"

  defp record_rdata(%{
         type: "TLSA",
         usage: usage,
         selector: selector,
         matching_type: matching_type,
         content: content
       }),
       do: "#{usage || 0} #{selector || 0} #{matching_type || 0} #{content}"

  defp record_rdata(%{
         type: "SSHFP",
         algorithm: algorithm,
         digest_type: digest_type,
         content: content
       }),
       do: "#{algorithm || 0} #{digest_type || 0} #{content}"

  defp record_rdata(%{type: type, priority: priority, content: content})
       when type in ["HTTPS", "SVCB"],
       do: "#{priority || 0} #{content}"

  defp record_rdata(record), do: record.content

  defp zone_status_badge_class("verified"), do: "badge badge-success badge-outline"
  defp zone_status_badge_class("pending"), do: "badge badge-warning badge-outline"
  defp zone_status_badge_class("error"), do: "badge badge-error badge-outline"
  defp zone_status_badge_class(_), do: "badge badge-outline"

  defp service_badge_class("ok"), do: "badge badge-success badge-outline"
  defp service_badge_class("conflict"), do: "badge badge-warning badge-outline"
  defp service_badge_class("error"), do: "badge badge-error badge-outline"
  defp service_badge_class("disabled"), do: "badge badge-ghost"
  defp service_badge_class("not_configured"), do: "badge badge-ghost"
  defp service_badge_class(_), do: "badge badge-outline"

  defp linked_domain_status_badge_class("verified"), do: "badge badge-success badge-outline"
  defp linked_domain_status_badge_class("pending"), do: "badge badge-warning badge-outline"
  defp linked_domain_status_badge_class(_), do: "badge badge-outline"

  defp check_badge_class("ok"), do: "badge badge-success badge-outline"
  defp check_badge_class("conflict"), do: "badge badge-warning badge-outline"
  defp check_badge_class("missing"), do: "badge badge-error badge-outline"
  defp check_badge_class("drift"), do: "badge badge-warning badge-outline"
  defp check_badge_class(_), do: "badge badge-outline"

  defp linked_domain_check_badge_class("ok"), do: "badge badge-success badge-outline"
  defp linked_domain_check_badge_class("missing"), do: "badge badge-error badge-outline"
  defp linked_domain_check_badge_class("review"), do: "badge badge-ghost"
  defp linked_domain_check_badge_class(_), do: "badge badge-outline"

  defp domain_health_badge_class(:ok), do: "badge badge-success badge-outline"
  defp domain_health_badge_class(:review), do: "badge badge-warning badge-outline"
  defp domain_health_badge_class(:warning), do: "badge badge-warning badge-outline"
  defp domain_health_badge_class(:missing), do: "badge badge-error badge-outline"
  defp domain_health_badge_class(_), do: "badge badge-outline"

  defp domain_health_category_label(:dns), do: "DNS"
  defp domain_health_category_label(:mail), do: "Mail"
  defp domain_health_category_label(:tls), do: "TLS"
  defp domain_health_category_label(:deliverability), do: "Deliverability"
  defp domain_health_category_label(category), do: category |> to_string() |> String.capitalize()

  defp format_zone_error(changeset) do
    changeset.errors
    |> Keyword.keys()
    |> Enum.map_join(", ", &to_string/1)
    |> case do
      "" -> "Zone verification failed"
      details -> "Zone verification failed (#{details})"
    end
  end

  defp format_service_error(service, changeset) do
    details =
      changeset.errors
      |> Keyword.keys()
      |> Enum.map_join(", ", &to_string/1)

    if details == "" do
      "Could not apply managed #{service} DNS"
    else
      "Could not apply managed #{service} DNS (#{details})"
    end
  end

  defp service_form_from_health(nil, defaults), do: to_form(defaults, as: :service_config)

  defp service_form_from_health(health, defaults) do
    defaults
    |> Map.merge(health.settings || %{})
    |> to_form(as: :service_config)
  end

  defp normalize_zone_params(params) when is_map(params) do
    Map.put(params, "force_https", Map.get(params, "force_https") in [true, "true", "on", "1"])
  end

  defp normalize_zone_params(params), do: params
end
