defmodule ElektrineWeb.ProfileLive.Domains do
  use ElektrineWeb, :live_view

  alias Elektrine.Accounts.User
  alias Elektrine.{DNS, DomainAccount, Domains, Profiles}
  alias Elektrine.Utils.SafeConvert
  alias ElektrineWeb.Platform.Integrations

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Profile Domains")
     |> assign(:user, user)
     |> assign_builtin_profile_url()
     |> assign_domain_account_summary()
     |> refresh_per_site_identities()
     |> assign(:custom_domains, Profiles.list_user_custom_domains(user.id))
     |> assign(:email_custom_domains, Integrations.email_custom_domains(user.id))}
  end

  @impl true
  def handle_event("update_builtin_profile_hosting", %{"mode" => mode}, socket)
      when mode in ["path", "platform"] do
    case DNS.update_builtin_user_zone_mode(socket.assigns.user, mode) do
      {:ok, user} ->
        message =
          case mode do
            "platform" -> "Built-in profile subdomain enabled."
            "path" -> "Built-in profile URL switched back to the main domain path."
          end

        {:noreply,
         socket
         |> assign(:user, user)
         |> assign(:current_user, user)
         |> assign_builtin_profile_url()
         |> assign_domain_account_summary()
         |> refresh_per_site_identities()
         |> put_flash(:info, message)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update built-in profile URL")}
    end
  end

  @impl true
  def handle_event(
        "create_per_site_identity",
        %{"site_key" => site_key, "base_domain" => base_domain} = params,
        socket
      ) do
    attrs = %{
      "site_key" => site_key,
      "base_domain" => base_domain,
      "display_name" => Map.get(params, "display_name")
    }

    case Profiles.create_per_site_identity(socket.assigns.user, attrs) do
      {:ok, _identity} ->
        {:noreply,
         socket
         |> put_flash(:info, "Per-site identity created")
         |> refresh_per_site_identities()}

      {:error, :invalid_base_domain} ->
        {:noreply, put_flash(socket, :error, "Choose one of your verified identity domains")}

      {:error, changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to create per-site identity: #{changeset_error(changeset)}"
         )}
    end
  end

  @impl true
  def handle_event("toggle_per_site_identity", %{"id" => id}, socket) do
    user_id = socket.assigns.user.id

    case Profiles.get_per_site_identity(event_id(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Per-site identity not found")}

      identity ->
        case Profiles.update_per_site_identity(identity, %{"enabled" => !identity.enabled}) do
          {:ok, _identity} ->
            {:noreply, refresh_per_site_identities(socket)}

          {:error, changeset} ->
            {:noreply,
             put_flash(socket, :error, "Failed to update identity: #{changeset_error(changeset)}")}
        end
    end
  end

  @impl true
  def handle_event("delete_per_site_identity", %{"id" => id}, socket) do
    user_id = socket.assigns.user.id

    case Profiles.get_per_site_identity(event_id(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Per-site identity not found")}

      identity ->
        case Profiles.delete_per_site_identity(identity) do
          {:ok, _identity} ->
            {:noreply,
             socket
             |> put_flash(:info, "Per-site identity removed")
             |> refresh_per_site_identities()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to remove identity: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("create_profile_domain", %{"domain" => domain}, socket) do
    case Profiles.create_custom_domain(socket.assigns.user, %{"domain" => domain}) do
      {:ok, _custom_domain} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Profile domain added. Publish the DNS records below, then verify ownership."
         )
         |> refresh_custom_domains()}

      {:error, changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to add profile domain: #{changeset_error(changeset)}"
         )}
    end
  end

  @impl true
  def handle_event("verify_profile_domain", %{"id" => id}, socket) do
    user_id = socket.assigns.user.id

    case Profiles.get_custom_domain(event_id(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Profile domain not found")}

      custom_domain ->
        case Profiles.verify_custom_domain(custom_domain) do
          {:ok, %{status: "verified"}} ->
            {:noreply,
             socket
             |> put_flash(:info, "Profile domain verified")
             |> refresh_custom_domains()}

          {:ok, pending_domain} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               pending_domain.last_error ||
                 "Verification TXT record not found yet. Check DNS and try again."
             )
             |> refresh_custom_domains()}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Failed to verify profile domain: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("delete_profile_domain", %{"id" => id}, socket) do
    user_id = socket.assigns.user.id

    case Profiles.get_custom_domain(event_id(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Profile domain not found")}

      custom_domain ->
        case Profiles.delete_custom_domain(custom_domain) do
          {:ok, _deleted_domain} ->
            {:noreply,
             socket
             |> put_flash(:info, "Profile domain removed")
             |> refresh_custom_domains()}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Failed to remove profile domain: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("create_email_domain", %{"domain" => domain}, socket) do
    user = socket.assigns.user

    case Integrations.create_email_custom_domain(user, %{"domain" => domain}) do
      {:ok, custom_domain} ->
        flash_message =
          if custom_domain.dkim_last_error do
            "Email domain added. Publish the DNS records below. DKIM sync needs attention: #{custom_domain.dkim_last_error}"
          else
            "Email domain added. Publish the DNS records below, then verify ownership."
          end

        {:noreply,
         socket
         |> put_flash(:info, flash_message)
         |> refresh_email_custom_domains()}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Failed to add email domain: #{error_message(changeset)}")}
    end
  end

  @impl true
  def handle_event("verify_email_domain", %{"id" => id}, socket) do
    user_id = socket.assigns.user.id

    case Integrations.email_custom_domain(event_id(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Email domain not found")}

      custom_domain ->
        case Integrations.verify_email_custom_domain(custom_domain) do
          {:ok, %{status: "verified"}} ->
            {:noreply,
             socket
             |> put_flash(:info, "Email domain verified")
             |> refresh_email_custom_domains()}

          {:ok, pending_domain} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               pending_domain.last_error ||
                 "Verification DNS records not found yet. Check DNS and try again."
             )
             |> refresh_email_custom_domains()}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Failed to verify email domain: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("sync_email_domain_dkim", %{"id" => id}, socket) do
    user_id = socket.assigns.user.id

    case Integrations.email_custom_domain(event_id(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Email domain not found")}

      custom_domain ->
        case Integrations.sync_email_custom_domain_dkim(custom_domain) do
          {:ok, synced_domain} ->
            if synced_domain.dkim_last_error do
              {:noreply,
               socket
               |> put_flash(:error, "DKIM sync failed: #{synced_domain.dkim_last_error}")
               |> refresh_email_custom_domains()}
            else
              {:noreply,
               socket
               |> put_flash(:info, "DKIM synced")
               |> refresh_email_custom_domains()}
            end
        end
    end
  end

  @impl true
  def handle_event("delete_email_domain", %{"id" => id}, socket) do
    user_id = socket.assigns.user.id

    case Integrations.email_custom_domain(event_id(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Email domain not found")}

      custom_domain ->
        case Integrations.delete_email_custom_domain(custom_domain) do
          {:ok, _deleted_domain} ->
            {:noreply,
             socket
             |> put_flash(:info, "Email domain removed")
             |> refresh_email_custom_domains()}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Failed to remove email domain: #{inspect(reason)}")}
        end
    end
  end

  # Route malformed forged LiveView event ids through the existing not-found path.
  defp event_id(value) do
    case SafeConvert.parse_id(value) do
      {:ok, id} -> id
      {:error, :invalid_id} -> 0
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-7xl px-4 pb-8 sm:px-6 lg:px-8 text-base-content">
      <ElektrineWeb.Components.Platform.ENav.e_nav
        active_tab="profile-domains"
        current_user={@current_user}
        class="mb-6"
      />

      <div class="space-y-6">
        <div class="grid gap-4 lg:grid-cols-2">
          <div class="card panel-card border border-base-300">
            <div class="card-body p-5">
              <div class="flex items-start gap-3">
                <div class="rounded-xl bg-primary/10 p-3 text-primary">
                  <.icon name="hero-user-circle" class="h-6 w-6" />
                </div>
                <div class="min-w-0 flex-1">
                  <h3 class="font-semibold">Profile Domains</h3>
                  <p class="mt-1 text-sm text-base-content/65">
                    Serve your profile directly from a custom root domain and publish a followable ActivityPub alias.
                  </p>
                </div>
              </div>
              <div class="mt-4 flex flex-wrap gap-2">
                <a href="#profile-domains" class="btn btn-primary btn-sm">Manage Profile Domains</a>
                <.link navigate={~p"/analytics/domains"} class="btn btn-ghost btn-sm">
                  View Analytics
                </.link>
              </div>
            </div>
          </div>

          <div class="card panel-card border border-base-300">
            <div class="card-body p-5">
              <div class="flex items-start gap-3">
                <div class="rounded-xl bg-secondary/10 p-3 text-secondary">
                  <.icon name="hero-envelope" class="h-6 w-6" />
                </div>
                <div class="min-w-0 flex-1">
                  <h3 class="font-semibold">Email Domains</h3>
                  <p class="mt-1 text-sm text-base-content/65">
                    Bring your own domain for mailbox addresses like <span class="font-mono">{@current_user.username}@your-domain.com</span>.
                  </p>
                </div>
              </div>
              <div class="mt-4">
                <a href="#email-domains" class="btn btn-secondary btn-sm">Manage Email Domains</a>
              </div>
            </div>
          </div>
        </div>

        <div class="card panel-card">
          <div class="card-body space-y-4">
            <.section_header
              title="Domain Account"
              description="Your domain account ties profile, sign-in, federation, mail, DID, and recovery discovery to one portable name."
              align="start"
            />

            <div class="grid gap-3 lg:grid-cols-3">
              <div class="rounded-2xl border border-base-content/10 bg-base-200/30 px-4 py-3">
                <div class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                  Current Identity
                </div>
                <div class="mt-2 font-mono text-sm break-all text-base-content/85">
                  {@domain_account_domain}
                </div>
              </div>
              <div class="rounded-2xl border border-base-content/10 bg-base-200/30 px-4 py-3">
                <div class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                  OIDC Subject
                </div>
                <div class="mt-2 font-mono text-sm break-all text-base-content/85">
                  {DomainAccount.subject(@domain_account_domain)}
                </div>
              </div>
              <div class="rounded-2xl border border-base-content/10 bg-base-200/30 px-4 py-3">
                <div class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                  DID
                </div>
                <div class="mt-2 font-mono text-sm break-all text-base-content/85">
                  {DomainAccount.did_for_domain(@domain_account_domain)}
                </div>
              </div>
            </div>

            <div class="grid gap-3 lg:grid-cols-2">
              <.identity_endpoint
                id="domain-account-built-in-endpoint"
                label="Domain Account"
                url={"https://#{@domain_account_domain}/.well-known/domain-account"}
              />
              <.identity_endpoint
                id="did-built-in-endpoint"
                label="DID Document"
                url={"https://#{@domain_account_domain}/.well-known/did.json"}
              />
            </div>

            <div class="rounded-2xl border border-base-content/10 bg-base-100 px-4 py-3">
              <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                <div>
                  <div class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                    Per-site Identities
                  </div>
                  <p class="mt-1 text-sm text-base-content/65">
                    Create scoped domains like
                    <span class="font-mono">hn.{@domain_account_domain}</span>
                    for apps that should not share the same subject.
                  </p>
                </div>
              </div>

              <.form
                for={%{}}
                phx-submit="create_per_site_identity"
                class="mt-4 grid gap-3 lg:grid-cols-[minmax(0,0.7fr)_minmax(0,1fr)_minmax(0,1fr)_auto]"
              >
                <input
                  type="text"
                  name="site_key"
                  placeholder="hn"
                  class="input input-bordered w-full"
                  pattern="[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
                  required
                />
                <div class="select select-bordered w-full">
                  <select name="base_domain" required>
                    <%= for domain <- @per_site_base_domains do %>
                      <option value={domain}>{domain}</option>
                    <% end %>
                  </select>
                </div>
                <input
                  type="text"
                  name="display_name"
                  placeholder="Display name"
                  class="input input-bordered w-full"
                />
                <button type="submit" class="btn btn-primary lg:min-w-32">Create</button>
              </.form>

              <%= if Enum.empty?(@per_site_identities) do %>
                <div class="mt-4 rounded-xl border border-dashed border-base-content/15 bg-base-200/20 px-4 py-5 text-sm text-base-content/60">
                  No saved per-site identities yet.
                </div>
              <% else %>
                <div class="mt-4 divide-y divide-base-content/10 overflow-hidden rounded-2xl border border-base-content/10">
                  <%= for identity <- @per_site_identities do %>
                    <div class="grid gap-3 bg-base-100 px-4 py-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] lg:items-center">
                      <div class="min-w-0">
                        <div class="flex flex-wrap items-center gap-2">
                          <div class="font-mono text-sm font-semibold break-all">
                            {identity.domain}
                          </div>
                          <span class={[
                            "badge badge-sm border-0",
                            if(identity.enabled,
                              do: "bg-success/15 text-success",
                              else: "bg-base-200 text-base-content/60"
                            )
                          ]}>
                            {if identity.enabled, do: "Enabled", else: "Paused"}
                          </span>
                        </div>
                        <div class="mt-1 font-mono text-xs break-all text-base-content/55">
                          {identity.email_alias}
                        </div>
                      </div>

                      <div class="min-w-0 space-y-1">
                        <div class="flex items-start gap-2">
                          <div class="font-mono text-xs break-all text-base-content/70 flex-1">
                            {identity.subject}
                          </div>
                          <.copy_button
                            id={"per-site-subject-#{identity.id}"}
                            content={identity.subject}
                            label="Copy subject"
                          />
                        </div>
                        <div class="flex items-start gap-2">
                          <div class="font-mono text-xs break-all text-base-content/70 flex-1">
                            {identity.did}
                          </div>
                          <.copy_button
                            id={"per-site-did-#{identity.id}"}
                            content={identity.did}
                            label="Copy DID"
                          />
                        </div>
                      </div>

                      <div class="flex gap-2 lg:justify-end">
                        <button
                          type="button"
                          phx-click="toggle_per_site_identity"
                          phx-value-id={identity.id}
                          class="btn btn-ghost btn-sm"
                        >
                          {if identity.enabled, do: "Pause", else: "Enable"}
                        </button>
                        <button
                          type="button"
                          phx-click="delete_per_site_identity"
                          phx-value-id={identity.id}
                          class="btn btn-ghost btn-sm text-error hover:bg-error/10"
                          data-confirm="Remove this per-site identity?"
                        >
                          Delete
                        </button>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <div class="mt-3 grid gap-3 lg:grid-cols-3">
                <%= for site <- ["hn", "spotify", "banking"] do %>
                  <div class="rounded-xl border border-base-content/10 bg-base-200/30 px-3 py-3">
                    <div class="font-mono text-xs break-all text-base-content/85">
                      {site}.{@domain_account_domain}
                    </div>
                    <div class="mt-2 font-mono text-xs break-all text-base-content/65">
                      {"domain:#{site}.#{@domain_account_domain}"}
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <div class="card panel-card">
          <div class="card-body space-y-4">
            <.section_header
              title="Default Profile URL"
              description="Your built-in profile URL stays available even if you add custom domains."
              align="start"
            />

            <div class="rounded-2xl border border-base-content/10 bg-base-200/30 px-4 py-3">
              <div class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                Built-in URL
              </div>
              <div class="mt-2 font-mono text-sm break-all text-base-content/85">
                {@default_profile_url || "Built-in subdomain currently handed off to DNS"}
              </div>

              <div class="mt-4 flex flex-wrap items-center gap-3">
                <%= if @built_in_subdomain_mode == "platform" do %>
                  <button
                    type="button"
                    class="btn btn-outline btn-sm"
                    phx-click="update_builtin_profile_hosting"
                    phx-value-mode="path"
                  >
                    Use main-domain URL
                  </button>
                  <span class="text-xs text-base-content/60">
                    Subdomain hosting is enabled for your handle.
                  </span>
                <% else %>
                  <button
                    type="button"
                    class="btn btn-primary btn-sm"
                    phx-click="update_builtin_profile_hosting"
                    phx-value-mode="platform"
                  >
                    Enable handle subdomain
                  </button>
                  <span class="text-xs text-base-content/60">
                    Elektrine manages DNS for
                    <span class="font-mono">
                      {user_handle(@user)}.{Domains.default_profile_domain()}
                    </span>
                    automatically.
                  </span>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <div id="profile-domains" class="card panel-card">
          <div class="card-body space-y-5">
            <.section_header
              title="Add Profile Domain"
              description="Use the bare root domain, like example.com. Once verified, that domain will serve your profile directly at /."
              align="start"
            />

            <.form for={%{}} phx-submit="create_profile_domain" class="space-y-3">
              <label class="label pb-1">
                <span class="label-text font-medium">Root Domain</span>
              </label>
              <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_auto]">
                <input
                  type="text"
                  name="domain"
                  placeholder="example.com"
                  class="input input-bordered w-full"
                  required
                />
                <button type="submit" class="btn btn-primary lg:min-w-40">Add Domain</button>
              </div>
            </.form>

            <div class="rounded-2xl border border-info/20 bg-info/5 px-4 py-3 text-sm text-base-content/75">
              Add the verification TXT record first. After verification, point the domain's apex/root host at the stable routing hostname shown below using your DNS provider's alias/flattening feature or edge proxy. That keeps the domain portable if the underlying hosting IPs change. Optional
              <span class="font-mono">www</span>
              traffic will redirect to the bare domain.
            </div>
          </div>
        </div>

        <div class="card panel-card">
          <div class="card-body p-0">
            <div class="border-b border-base-content/10 px-5 py-4">
              <h3 class="text-lg font-semibold">Connected Domains</h3>
              <p class="text-sm text-base-content/70 mt-1">
                Verified domains serve your profile at the domain root with no handle path.
              </p>
            </div>

            <%= if Enum.empty?(@custom_domains) do %>
              <div class="px-5 py-10">
                <div class="rounded-2xl border border-dashed border-base-content/15 bg-base-200/20 px-6 py-8 text-center">
                  <div class="text-sm font-medium text-base-content/75">
                    No profile domains added yet
                  </div>
                  <div class="mt-1 text-xs text-base-content/50">
                    Add one above to generate the verification record.
                  </div>
                </div>
              </div>
            <% else %>
              <div class="divide-y divide-base-content/10">
                <%= for custom_domain <- @custom_domains do %>
                  <div class="px-5 py-5">
                    <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                      <div class="min-w-0 flex-1 space-y-4">
                        <div class="space-y-2">
                          <div class="flex flex-wrap items-center gap-2">
                            <h4 class="truncate text-base font-semibold">{custom_domain.domain}</h4>
                            <span class={[
                              "badge badge-sm border-0 font-medium",
                              domain_status_badge(custom_domain.status)
                            ]}>
                              {String.capitalize(custom_domain.status)}
                            </span>
                          </div>

                          <div class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                            Public URL
                          </div>
                          <div class="mt-1 flex items-start gap-2">
                            <div class="font-mono text-sm break-all text-base-content/85 flex-1">
                              {"https://#{custom_domain.domain}"}
                            </div>
                            <.copy_button
                              id={"profile-domain-public-url-#{custom_domain.id}"}
                              content={"https://#{custom_domain.domain}"}
                              label="Copy public URL"
                            />
                          </div>
                        </div>

                        <div class="space-y-2">
                          <div class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                            ActivityPub Alias
                          </div>
                          <div class="text-xs text-base-content/55">
                            <%= if custom_domain.status == "verified" do %>
                              Followable canonical identity on <span class="font-mono">{custom_domain.domain}</span>.
                            <% else %>
                              Becomes a canonical followable identity after verification.
                            <% end %>
                          </div>
                          <div class="mt-1 flex items-start gap-2">
                            <div class="font-mono text-sm break-all text-base-content/85 flex-1">
                              {"@#{@user.username}@#{custom_domain.domain}"}
                            </div>
                            <.copy_button
                              id={"profile-domain-activitypub-alias-#{custom_domain.id}"}
                              content={"@#{@user.username}@#{custom_domain.domain}"}
                              label="Copy ActivityPub alias"
                            />
                          </div>
                        </div>

                        <%= if custom_domain.status == "verified" do %>
                          <div class="grid gap-3 lg:grid-cols-2">
                            <.identity_endpoint
                              id={"domain-account-endpoint-#{custom_domain.id}"}
                              label="Domain Account"
                              url={"https://#{custom_domain.domain}/.well-known/domain-account"}
                            />
                            <.identity_endpoint
                              id={"did-endpoint-#{custom_domain.id}"}
                              label="DID Document"
                              url={"https://#{custom_domain.domain}/.well-known/did.json"}
                            />
                            <.identity_endpoint
                              id={"activitypub-actor-#{custom_domain.id}"}
                              label="ActivityPub Actor"
                              url={"https://#{custom_domain.domain}/users/#{user_handle(@user)}"}
                            />
                            <.identity_endpoint
                              id={"domain-account-subject-#{custom_domain.id}"}
                              label="OIDC Subject"
                              url={DomainAccount.subject(custom_domain.domain)}
                            />
                          </div>
                        <% end %>

                        <%= if Elektrine.Strings.present?(custom_domain.last_error) do %>
                          <div class="rounded-xl border border-error/20 bg-error/5 px-3 py-2 text-xs leading-5 text-error">
                            {custom_domain.last_error}
                          </div>
                        <% end %>

                        <div class="overflow-hidden rounded-2xl border border-base-content/10">
                          <div class="border-b border-base-content/10 bg-base-200/35 px-4 py-3">
                            <div class="text-[11px] font-semibold uppercase tracking-[0.18em] text-base-content/45">
                              DNS Records
                            </div>
                          </div>

                          <div class="divide-y divide-base-content/10 bg-base-100">
                            <%= for {record, index} <-
                                  Enum.with_index(
                                    Profiles.dns_records_for_custom_domain(custom_domain)
                                  ) do %>
                              <div class="grid gap-3 px-4 py-3 sm:grid-cols-[120px_minmax(0,0.9fr)_minmax(0,1.3fr)]">
                                <div class="flex items-start sm:items-center">
                                  <span class="badge badge-outline badge-sm font-medium">
                                    {record.type}
                                  </span>
                                </div>

                                <div class="min-w-0">
                                  <div class="text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/45">
                                    Host
                                  </div>
                                  <div class="mt-1 flex items-start gap-2">
                                    <div class="font-mono text-xs leading-5 break-all text-base-content/80 flex-1">
                                      {record.host}
                                    </div>
                                    <.copy_button
                                      id={"profile-domain-#{custom_domain.id}-record-#{index}-host"}
                                      content={record.host}
                                      label={"Copy #{record.type} host"}
                                    />
                                  </div>
                                </div>

                                <div class="min-w-0">
                                  <div class="text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/45">
                                    Value
                                  </div>
                                  <div class="mt-1 text-xs font-medium text-base-content/55">
                                    {record.label}
                                  </div>
                                  <div class="mt-1 flex items-start gap-2">
                                    <div class="font-mono text-xs leading-5 break-all text-base-content/80 flex-1">
                                      {record.value}
                                    </div>
                                    <.copy_button
                                      id={"profile-domain-#{custom_domain.id}-record-#{index}-value"}
                                      content={record.value}
                                      label={"Copy #{record.type} value"}
                                    />
                                  </div>
                                </div>
                              </div>
                            <% end %>
                          </div>
                        </div>
                      </div>

                      <div class="flex w-full flex-col gap-2 xl:w-40 xl:shrink-0">
                        <%= if custom_domain.status == "verified" do %>
                          <.link
                            href={"https://#{custom_domain.domain}"}
                            target="_blank"
                            class="btn btn-secondary btn-sm w-full"
                          >
                            View Domain
                          </.link>
                        <% else %>
                          <button
                            type="button"
                            phx-click="verify_profile_domain"
                            phx-value-id={custom_domain.id}
                            class="btn btn-secondary btn-sm w-full"
                          >
                            Verify
                          </button>
                        <% end %>

                        <button
                          type="button"
                          phx-click="delete_profile_domain"
                          phx-value-id={custom_domain.id}
                          class="btn btn-ghost btn-sm w-full text-error hover:bg-error/10"
                          data-confirm="Remove this profile domain?"
                        >
                          Delete
                        </button>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <div id="email-domains" class="card panel-card">
          <div class="card-body space-y-5">
            <.section_header
              title="Add Email Domain"
              description="Use a domain for mailbox addresses like username@your-domain.com."
              align="start"
            />

            <.form for={%{}} phx-submit="create_email_domain" class="space-y-3">
              <label class="label pb-1">
                <span class="label-text font-medium">Email Domain</span>
              </label>
              <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_auto]">
                <input
                  type="text"
                  name="domain"
                  placeholder="mail.example.com"
                  class="input input-bordered w-full"
                  required
                />
                <button type="submit" class="btn btn-secondary lg:min-w-40">Add Domain</button>
              </div>
            </.form>

            <div class="rounded-2xl border border-info/20 bg-info/5 px-4 py-3 text-sm text-base-content/75">
              Publish the TXT, MX, SPF, DKIM, and DMARC records shown after adding the domain. Once verified, mail to
              <span class="font-mono">{@user.username}@your-domain.com</span>
              will route into your mailbox.
            </div>
          </div>
        </div>

        <div class="card panel-card">
          <div class="card-body p-0">
            <div class="border-b border-base-content/10 px-5 py-4">
              <h3 class="text-lg font-semibold">Connected Email Domains</h3>
              <p class="text-sm text-base-content/70 mt-1">
                Verified domains can receive mail for your username at that domain.
              </p>
            </div>

            <%= if Enum.empty?(@email_custom_domains) do %>
              <div class="px-5 py-10">
                <div class="rounded-2xl border border-dashed border-base-content/15 bg-base-200/20 px-6 py-8 text-center">
                  <div class="text-sm font-medium text-base-content/75">
                    No email domains added yet
                  </div>
                  <div class="mt-1 text-xs text-base-content/50">
                    Add one above to generate mail routing and verification records.
                  </div>
                </div>
              </div>
            <% else %>
              <div class="divide-y divide-base-content/10">
                <%= for custom_domain <- @email_custom_domains do %>
                  <div class="px-5 py-5">
                    <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                      <div class="min-w-0 flex-1 space-y-4">
                        <div class="space-y-2">
                          <div class="flex flex-wrap items-center gap-2">
                            <h4 class="truncate text-base font-semibold">{custom_domain.domain}</h4>
                            <span class={[
                              "badge badge-sm border-0 font-medium",
                              domain_status_badge(custom_domain.status)
                            ]}>
                              {String.capitalize(custom_domain.status)}
                            </span>
                          </div>

                          <div class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
                            Primary Address
                          </div>
                          <div class="mt-1 flex items-start gap-2">
                            <div class="font-mono text-sm break-all text-base-content/85 flex-1">
                              {@user.username}@{custom_domain.domain}
                            </div>
                            <.copy_button
                              id={"email-domain-primary-address-#{custom_domain.id}"}
                              content={"#{@user.username}@#{custom_domain.domain}"}
                              label="Copy primary email address"
                            />
                          </div>
                        </div>

                        <%= if Elektrine.Strings.present?(custom_domain.last_error) do %>
                          <div class="rounded-xl border border-error/20 bg-error/5 px-3 py-2 text-xs leading-5 text-error">
                            {custom_domain.last_error}
                          </div>
                        <% end %>

                        <%= if Elektrine.Strings.present?(custom_domain.dkim_last_error) do %>
                          <div class="rounded-xl border border-warning/20 bg-warning/10 px-3 py-2 text-xs leading-5 text-warning-content">
                            DKIM: {custom_domain.dkim_last_error}
                          </div>
                        <% end %>

                        <div class="overflow-hidden rounded-2xl border border-base-content/10">
                          <div class="border-b border-base-content/10 bg-base-200/35 px-4 py-3">
                            <div class="text-[11px] font-semibold uppercase tracking-[0.18em] text-base-content/45">
                              DNS Records
                            </div>
                          </div>

                          <div class="divide-y divide-base-content/10 bg-base-100">
                            <%= for {record, index} <-
                                  Enum.with_index(
                                    Integrations.email_custom_domain_dns_records(custom_domain)
                                  ) do %>
                              <div class="grid gap-3 px-4 py-3 sm:grid-cols-[120px_minmax(0,0.9fr)_minmax(0,1.3fr)]">
                                <div class="flex items-start sm:items-center">
                                  <span class="badge badge-outline badge-sm font-medium">
                                    {record.type}
                                  </span>
                                </div>

                                <div class="min-w-0">
                                  <div class="text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/45">
                                    Host
                                  </div>
                                  <div class="mt-1 flex items-start gap-2">
                                    <div class="font-mono text-xs leading-5 break-all text-base-content/80 flex-1">
                                      {record.host}
                                    </div>
                                    <.copy_button
                                      id={"email-domain-#{custom_domain.id}-record-#{index}-host"}
                                      content={record.host}
                                      label={"Copy #{record.type} host"}
                                    />
                                  </div>
                                </div>

                                <div class="min-w-0">
                                  <div class="flex flex-wrap items-center gap-2 text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/45">
                                    <span>Value</span>
                                    <span
                                      :if={Map.get(record, :priority)}
                                      class="rounded-full bg-base-200 px-2 py-0.5 text-[10px] normal-case tracking-normal text-base-content/65"
                                    >
                                      priority {record.priority}
                                    </span>
                                  </div>
                                  <div class="mt-1 text-xs font-medium text-base-content/55">
                                    {record.label}
                                  </div>
                                  <div class="mt-1 flex items-start gap-2">
                                    <div class="font-mono text-xs leading-5 break-all text-base-content/80 flex-1">
                                      {record.value}
                                    </div>
                                    <.copy_button
                                      id={"email-domain-#{custom_domain.id}-record-#{index}-value"}
                                      content={record.value}
                                      label={"Copy #{record.type} value"}
                                    />
                                  </div>
                                </div>
                              </div>
                            <% end %>
                          </div>
                        </div>
                      </div>

                      <div class="flex w-full flex-col gap-2 xl:w-40 xl:shrink-0">
                        <%= if custom_domain.status != "verified" do %>
                          <button
                            type="button"
                            phx-click="verify_email_domain"
                            phx-value-id={custom_domain.id}
                            class="btn btn-secondary btn-sm w-full"
                          >
                            Verify
                          </button>
                        <% end %>

                        <button
                          type="button"
                          phx-click="sync_email_domain_dkim"
                          phx-value-id={custom_domain.id}
                          class="btn btn-ghost btn-sm w-full"
                        >
                          Sync DKIM
                        </button>

                        <button
                          type="button"
                          phx-click="delete_email_domain"
                          phx-value-id={custom_domain.id}
                          class="btn btn-ghost btn-sm w-full text-error hover:bg-error/10"
                          data-confirm="Remove this email domain?"
                        >
                          Delete
                        </button>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp refresh_custom_domains(socket) do
    socket
    |> assign(:custom_domains, Profiles.list_user_custom_domains(socket.assigns.user.id))
    |> refresh_per_site_identities()
  end

  defp refresh_email_custom_domains(socket) do
    assign(
      socket,
      :email_custom_domains,
      Integrations.email_custom_domains(socket.assigns.user.id)
    )
  end

  defp assign_builtin_profile_url(socket) do
    user = socket.assigns.user

    socket
    |> assign(:default_profile_url, Domains.default_profile_url_for_user(user))
    |> assign(:built_in_subdomain_mode, User.built_in_subdomain_mode(user))
  end

  defp assign_domain_account_summary(socket) do
    user = socket.assigns.user
    handle = user_handle(user)
    domain = "#{handle}.#{Domains.default_profile_domain()}"

    assign(socket, :domain_account_domain, domain)
  end

  defp refresh_per_site_identities(socket) do
    user = socket.assigns.user

    socket
    |> assign(:per_site_identities, Profiles.list_user_per_site_identities(user))
    |> assign(:per_site_base_domains, Profiles.available_per_site_base_domains(user))
  end

  defp user_handle(%{handle: handle, username: username}), do: handle || username
  defp user_handle(_), do: nil

  defp changeset_error(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _opts}} -> "#{field} #{message}" end)
    |> List.first()
    |> Kernel.||("unknown error")
  end

  defp error_message(%Ecto.Changeset{} = changeset), do: changeset_error(changeset)
  defp error_message(reason), do: inspect(reason)

  attr :id, :string, required: true
  attr :content, :string, required: true
  attr :label, :string, required: true

  defp copy_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-hook="CopyToClipboard"
      data-content={@content}
      class="btn btn-ghost btn-xs h-7 min-h-0 shrink-0 px-2 text-base-content/55 hover:text-base-content"
      title={@label}
      aria-label={@label}
    >
      <.icon name="hero-clipboard-document" class="h-4 w-4" />
    </button>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :url, :string, required: true

  defp identity_endpoint(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-content/10 bg-base-200/30 px-4 py-3">
      <div class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
        {@label}
      </div>
      <div class="mt-2 flex items-start gap-2">
        <div class="font-mono text-xs leading-5 break-all text-base-content/80 flex-1">
          {@url}
        </div>
        <.copy_button id={"#{@id}-copy"} content={@url} label={"Copy #{@label}"} />
      </div>
    </div>
    """
  end

  defp domain_status_badge("verified"), do: "bg-success/15 text-success"
  defp domain_status_badge("pending"), do: "bg-secondary/15 text-secondary"
  defp domain_status_badge(_), do: "bg-base-200 text-base-content/70"
end
