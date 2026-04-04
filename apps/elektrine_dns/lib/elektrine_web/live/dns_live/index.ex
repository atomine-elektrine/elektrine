defmodule ElektrineWeb.DNSLive.Index do
  use ElektrineDNSWeb, :live_view

  alias Elektrine.DNS
  alias Elektrine.DNS.MailSecurity
  alias Elektrine.DNS.Record
  alias Elektrine.DNS.Zone
  alias Elektrine.Profiles.CustomDomains, as: ProfileCustomDomains

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
       |> assign(:record_types, DNS.supported_record_types())
       |> assign(:zones, zones)
       |> assign(:active_zone, active_zone)
       |> assign(:linked_domains, linked_domains(active_zone, user.id))
       |> assign(:service_health, service_health(active_zone))
       |> assign(:service_forms, service_forms(active_zone))
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
     |> assign(:linked_domains, linked_domains(active_zone, socket.assigns.current_user.id))
     |> assign(:service_health, service_health(active_zone))
     |> assign(:service_forms, service_forms(active_zone))
     |> assign(:zone_settings_form, zone_settings_form(active_zone))
     |> assign(:editing_record_id, nil)
     |> assign(:record_form, record_form(active_zone))}
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
          |> Enum.reject(&review_only_record?/1)
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
    <div class="mx-auto max-w-7xl space-y-8 px-4 pb-2 sm:px-6 lg:px-8">
      <.e_nav active_tab="dns" current_user={@current_user} class="mb-6" />

      <div class="space-y-8">
        <div class="grid gap-6">
          <div class="card panel-card">
            <div class="card-body p-6 space-y-6">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <h2 class="card-title text-lg">Zones</h2>
                  <p class="text-sm text-base-content/65">Select a zone or add a new one.</p>
                </div>
                <span class="badge badge-outline">{length(@zones)}</span>
              </div>

              <%= if @zones == [] do %>
                <div class="rounded-2xl border border-dashed border-base-300 bg-base-200/55 p-5 text-sm text-base-content/70">
                  No DNS zones yet. Create your first one below.
                </div>
              <% else %>
                <div class="overflow-hidden rounded-xl border border-base-300 bg-base-100/70">
                  <div class="grid grid-cols-[minmax(0,1fr)_110px_110px] gap-3 border-b border-base-300/80 px-4 py-2 text-xs font-semibold uppercase tracking-wide text-base-content/50">
                    <span>Zone</span>
                    <span>Status</span>
                    <span>TTL</span>
                  </div>
                  <%= for zone <- @zones do %>
                    <.link
                      navigate={~p"/dns?zone_id=#{zone.id}"}
                      class={compact_zone_link_class(zone, @active_zone)}
                    >
                      <div class="min-w-0">
                        <p class="font-medium">{zone.domain}</p>
                        <p class="truncate text-xs text-base-content/60">zone</p>
                      </div>
                      <span class={zone_status_badge_class(zone.status)}>{zone.status}</span>
                      <span class="text-xs font-mono text-base-content/70">{zone.default_ttl}</span>
                    </.link>
                  <% end %>
                </div>
              <% end %>

              <div class="rounded-xl border border-base-300 bg-base-200/30 p-4">
                <div class="flex items-start gap-3">
                  <div class="flex h-10 w-10 items-center justify-center rounded-xl bg-base-100 text-primary">
                    <.icon name="hero-plus-circle" class="h-5 w-5" />
                  </div>
                  <div class="space-y-1.5">
                    <h3 class="font-semibold">Add zone</h3>
                    <p class="text-sm text-base-content/65">Create a new authoritative zone.</p>
                  </div>
                </div>

                <.simple_form
                  for={@zone_form}
                  bare={true}
                  phx-change="zone_validate"
                  phx-submit="zone_create"
                >
                  <div class="grid gap-x-4 gap-y-6 md:grid-cols-[minmax(0,1fr)_220px]">
                    <.input
                      field={@zone_form[:domain]}
                      label="Domain"
                      placeholder="example.com"
                      required
                    />
                    <.input field={@zone_form[:default_ttl]} type="number" label="Default TTL" />
                  </div>
                  <:actions>
                    <.button>Provision zone</.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
          </div>

          <%= if @active_zone do %>
            <div class="flex flex-col gap-6">
              <div class="card panel-card">
                <div class="card-body p-6">
                  <div class="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
                    <div class="space-y-3">
                      <div class="flex items-center gap-3">
                        <div class="flex h-12 w-12 items-center justify-center rounded-xl bg-base-200 text-info">
                          <.icon name="hero-circle-stack" class="h-6 w-6" />
                        </div>
                        <div>
                          <h2 class="text-2xl font-semibold tracking-tight">{@active_zone.domain}</h2>
                          <p class="text-sm text-base-content/65">
                            Default TTL {@active_zone.default_ttl}
                          </p>
                        </div>
                      </div>

                      <div class="flex flex-wrap items-center gap-2">
                        <span class={zone_status_badge_class(@active_zone.status)}>
                          {@active_zone.status}
                        </span>
                        <%= if @active_zone.verified_at do %>
                          <span class="badge badge-outline">
                            Verified {Calendar.strftime(@active_zone.verified_at, "%Y-%m-%d")}
                          </span>
                        <% end %>
                      </div>
                    </div>

                    <div class="flex flex-wrap gap-2">
                      <button
                        type="button"
                        phx-click="zone_verify"
                        phx-value-id={@active_zone.id}
                        class="btn btn-sm btn-primary"
                      >
                        <.icon name="hero-check-badge" class="h-4 w-4" /> Verify
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
                    </div>
                  </div>

                  <%= if @active_zone.last_error do %>
                    <div class="alert alert-warning mt-5 text-sm">{@active_zone.last_error}</div>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <%= if @active_zone do %>
          <div class="order-2 card panel-card">
            <div class="card-body space-y-4 p-6">
              <div class="space-y-1">
                <h3 class="card-title text-lg">Linked custom domains</h3>
                <p class="text-sm text-base-content/70">
                  Shows whether this DNS zone is already claimed in your profile or email custom domain settings.
                </p>
              </div>

              <%= if @linked_domains == [] do %>
                <p class="text-sm text-base-content/60">
                  No profile or custom email domains from account settings currently match this zone.
                </p>
              <% else %>
                <div class="space-y-3">
                  <%= for linked_domain <- @linked_domains do %>
                    <div class="rounded-xl border border-base-300 bg-base-200/30 p-4">
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

                      <div class="mt-4 grid gap-2 md:grid-cols-2 xl:grid-cols-3 text-sm">
                        <%= for check <- linked_domain.checks do %>
                          <div class="rounded-lg bg-base-100/70 px-3 py-2">
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
                </div>
              <% end %>
            </div>
          </div>

          <div class="order-3 card panel-card">
            <div class="card-body p-6">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <h3 class="card-title text-lg">Managed services</h3>
                  <p class="text-sm text-base-content/70">
                    Apply opinionated DNS packages for mail and web on this zone.
                  </p>
                </div>
              </div>

              <div class="mt-4 space-y-3">
                <%= for health <- @service_health do %>
                  <div class="rounded-xl border border-base-300 bg-base-200/30 p-4 shadow-sm">
                    <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                      <div class="min-w-0 xl:w-72">
                        <div class="flex items-center gap-2">
                          <p class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
                            {health.service}
                          </p>
                          <span class={service_badge_class(health.status)}>{health.status}</span>
                        </div>
                        <p class="mt-1 text-sm text-base-content/65">
                          {service_summary(health.service)}
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
                          <div class="alert alert-warning px-3 py-2 text-sm">{health.last_error}</div>
                        <% end %>

                        <%= if health.checks != [] do %>
                          <div class="grid gap-2 md:grid-cols-2 xl:grid-cols-3 text-sm">
                            <%= for check <- health.checks do %>
                              <div class="flex items-center justify-between gap-3 rounded-lg bg-base-100/70 px-3 py-2">
                                <span>{check.label}</span>
                                <span class={check_badge_class(check.status)}>{check.status}</span>
                              </div>
                            <% end %>
                          </div>
                        <% end %>

                        <.simple_form
                          for={Map.fetch!(@service_forms, health.service)}
                          bare={true}
                          phx-submit="service_apply"
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
                                label="VPN API host"
                                placeholder="wg"
                              />
                              <.input
                                field={Map.fetch!(@service_forms, health.service)[:vpn_api_target]}
                                label="VPN API target"
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
          </div>

          <div class="order-1 space-y-6">
            <div class="card panel-card">
              <div class="card-body p-6">
                <div class="flex items-start justify-between gap-3">
                  <div class="space-y-1">
                    <h3 class="card-title text-lg">Records</h3>
                    <p class="text-sm text-base-content/70">
                      Review every record in this zone. Managed records stay read-only here.
                    </p>
                  </div>
                </div>

                <%= if @editing_record_id do %>
                  <div class="mt-5 space-y-4 rounded-xl border border-base-300 bg-base-200/30 p-5">
                    <div class="space-y-1">
                      <h4 class="font-semibold">Edit record</h4>
                      <p class="text-sm text-base-content/65">
                        Update the hostname, record type, and any type-specific fields.
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
                        <.input
                          field={@record_form[:type]}
                          type="select"
                          label="Type"
                          options={Enum.map(@record_types, &{&1, &1})}
                        />
                        <% value_spec = record_value_spec(@record_form) %>
                        <.input
                          field={@record_form[:content]}
                          label={value_spec.label}
                          placeholder={value_spec.placeholder}
                          required
                        />
                        <.input field={@record_form[:ttl]} type="number" label="TTL" />
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
                  <div class="mt-4 rounded-2xl border border-dashed border-base-300 bg-base-200/55 p-5 text-sm text-base-content/70">
                    No custom records yet. Use managed services for the common setup, then add custom overrides only when needed.
                  </div>
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
                            <td>
                              <div class="flex items-center gap-2">
                                <span>{record.name}</span>
                                <%= if record.managed do %>
                                  <span class="badge badge-outline badge-xs">managed</span>
                                <% end %>
                              </div>
                            </td>
                            <td>{record.type}</td>
                            <td class="font-mono text-xs break-all">{record_rdata(record)}</td>
                            <td>{record.ttl}</td>
                            <td>
                              <div class="flex gap-2">
                                <%= if record.managed do %>
                                  <span class="text-xs text-base-content/60">
                                    Use managed services
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

            <div class="card panel-card">
              <div class="card-body p-6">
                <div class="flex items-start justify-between gap-3">
                  <div class="space-y-1">
                    <h3 class="card-title text-lg">Add record</h3>
                    <p class="text-sm text-base-content/70">
                      Use `@` for the apex or a short host like `www`, `mail`, or `vpn`.
                    </p>
                  </div>
                </div>
                <.simple_form
                  for={@record_form}
                  bare={true}
                  phx-change="record_validate"
                  phx-submit="record_create"
                >
                  <div class="grid gap-x-4 gap-y-5 md:grid-cols-2 xl:grid-cols-3">
                    <.input field={@record_form[:name]} label="Name" placeholder="@ or www" required />
                    <.input
                      field={@record_form[:type]}
                      type="select"
                      label="Type"
                      options={Enum.map(@record_types, &{&1, &1})}
                    />
                    <% value_spec = record_value_spec(@record_form) %>
                    <.input
                      field={@record_form[:content]}
                      label={value_spec.label}
                      placeholder={value_spec.placeholder}
                      required
                    />
                    <.input field={@record_form[:ttl]} type="number" label="TTL" />
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
                    <.button>Add DNS record</.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>

            <%= if @active_zone.status != "verified" do %>
              <div class="card panel-card">
                <div class="card-body space-y-4 p-6">
                  <div class="space-y-1">
                    <h3 class="card-title text-lg">Setup</h3>
                    <p class="text-sm text-base-content/70">
                      Add these onboarding records at your DNS provider, then run verification again.
                    </p>
                  </div>
                  <div class="overflow-x-auto">
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
            <% end %>
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
      "grid grid-cols-[minmax(0,1fr)_110px_110px] items-center gap-3 px-4 py-3 transition",
      if(active?,
        do: "bg-primary/8",
        else: "hover:bg-base-200/60"
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

  defp linked_domain_check(zone, %{type: "ALIAS/CNAME", host: host, value: value, label: label}) do
    if normalize_dns_name(host) == normalize_dns_name(zone.domain) do
      %{
        label: label,
        status: "review",
        addable: false,
        detail: "Apex routing to #{value} is provider-specific. Review manually."
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
      addable: not review_only_record?(expected_record),
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
      apply(module, :list_user_custom_domains, [user_id])
    else
      []
    end
  end

  defp email_custom_domain_records(custom_domain) do
    module = Module.concat([Elektrine, Email, CustomDomains])

    if Code.ensure_loaded?(module) and
         function_exported?(module, :dns_records_for_custom_domain, 1) do
      apply(module, :dns_records_for_custom_domain, [custom_domain])
    else
      []
    end
  end

  defp review_only_record?(%{type: "ALIAS/CNAME", host: host}) do
    host
    |> normalize_dns_name()
    |> String.starts_with?("www.")
    |> Kernel.not()
  end

  defp review_only_record?(_), do: false

  defp record_exists_for_expected?(%Zone{} = zone, expected_record) do
    Enum.any?(zone.records || [], &record_matches_expected?(&1, expected_record, zone))
  end

  defp expected_record_to_attrs(%Zone{} = zone, expected_record) do
    attrs = %{
      "name" => expected_record_name(zone, expected_record.host),
      "type" => normalize_expected_type(expected_record.type),
      "content" => expected_record.value,
      "ttl" => zone.default_ttl
    }

    case expected_record.priority do
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

  defp normalize_expected_type("ALIAS/CNAME"), do: "CNAME"
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
    normalize_dns_name(content) == normalize_dns_name(expected_record.value) and
      (is_nil(expected_record.priority) or priority == expected_record.priority)
  end

  defp record_value_matches?(%Record{type: type, content: content}, expected_record)
       when type in ["CNAME", "NS"] do
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

    if is_nil(expected_record.priority) do
      base
    else
      base <> " (priority #{expected_record.priority})"
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
    do: "MX, SPF, DKIM, DMARC, MTA-STS, TLS-RPT, and common mail aliases."

  defp service_summary("web"), do: "WWW alias and future web onboarding records."
  defp service_summary("turn"), do: "TURN hostname alias for self-hosted WebRTC relay access."

  defp service_summary("vpn"),
    do: "VPN endpoint alias with an optional separate admin or API hostname."

  defp service_summary("bluesky"), do: "Bluesky PDS hostname alias for managed handles."
  defp service_summary(_), do: "Managed DNS package."

  defp record_value_spec(form) do
    case record_form_type(form) do
      "DNSKEY" -> %{label: "Public key", placeholder: "AwEAAc..."}
      "DS" -> %{label: "Digest", placeholder: "2BB183AF5F22588179A53B0A98631FAD1A292118"}
      "TLSA" -> %{label: "Certificate data", placeholder: "A1B2C3D4..."}
      "TXT" -> %{label: "Text value", placeholder: "v=spf1 mx ~all"}
      _ -> %{label: "Value", placeholder: "198.51.100.42"}
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
end
