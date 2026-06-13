defmodule ElektrineEmailWeb.EmailLive.Settings.DomainSettings do
  @moduledoc """
  Alias, custom domain, and mailbox forwarding settings: event handlers,
  async result processing, tab data loading, and the aliases tab render
  function for `ElektrineEmailWeb.EmailLive.Settings`.
  """

  use Phoenix.Component

  import Phoenix.LiveView, only: [put_flash: 3, start_async: 3]
  import ElektrineWeb.CoreComponents
  import ElektrineEmailWeb.EmailLive.EmailHelpers, only: [mailbox_addresses: 2]
  import ElektrineEmailWeb.EmailLive.Settings.Helpers

  alias Elektrine.Email
  alias Elektrine.Email.{Alias, Aliases}
  alias ElektrineEmailWeb.UserErrorHelpers

  # Tab data loading

  def load_tab_data(socket, "aliases") do
    assign_aliases_tab(socket, socket.assigns.current_user.id)
  end

  # Alias Events

  def handle_event("create_alias", params, socket) do
    params = normalize_alias_create_params(params)
    user_id = socket.assigns.current_user.id
    username = params["username"]
    domain = params["domain"]
    target_email = params["target_email"]
    description = params["description"]

    alias_attrs = %{
      username: username,
      domain: domain,
      user_id: user_id,
      target_email: if(Elektrine.Strings.present?(target_email), do: target_email, else: nil),
      description: if(Elektrine.Strings.present?(description), do: description, else: nil)
    }

    case Aliases.create_alias(alias_attrs) do
      {:ok, _alias} ->
        {:noreply,
         socket
         |> put_flash(:info, "Alias created successfully")
         |> assign(:aliases, Aliases.list_aliases(user_id))}

      {:error, changeset} ->
        error = get_changeset_error(changeset)
        {:noreply, put_flash(socket, :error, "Failed to create alias: #{error}")}
    end
  end

  def handle_event("toggle_alias", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Aliases.get_alias(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Alias not found")}

      alias_record ->
        case Aliases.update_alias(alias_record, %{enabled: !alias_record.enabled}) do
          {:ok, _updated_alias} ->
            status = if alias_record.enabled, do: "disabled", else: "enabled"

            {:noreply,
             socket
             |> put_flash(:info, "Alias #{status}")
             |> assign(:aliases, Aliases.list_aliases(user_id))}

          {:error, changeset} ->
            error = get_changeset_error(changeset)
            {:noreply, put_flash(socket, :error, "Failed to update alias: #{error}")}
        end
    end
  end

  def handle_event("delete_alias", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Aliases.get_alias(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Alias not found")}

      alias_record ->
        {:ok, _} = Aliases.delete_alias(alias_record)

        {:noreply,
         socket
         |> put_flash(:info, "Alias deleted")
         |> assign(:aliases, Aliases.list_aliases(user_id))}
    end
  end

  # Custom Domain Events

  def handle_event("create_custom_domain", %{"domain" => domain}, socket) do
    user = socket.assigns.current_user

    case Email.create_custom_domain(user, %{"domain" => domain}) do
      {:ok, custom_domain} ->
        flash_message =
          if custom_domain.dkim_last_error do
            "Custom domain added. Publish the DNS records below. DKIM sync to Haraka needs attention: #{custom_domain.dkim_last_error}"
          else
            "Custom domain added. Publish the DNS records below, then verify ownership."
          end

        {:noreply,
         socket
         |> put_flash(:info, flash_message)
         |> assign_aliases_tab(user.id)}

      {:error, changeset} ->
        error = get_changeset_error(changeset)
        {:noreply, put_flash(socket, :error, "Failed to add custom domain: #{error}")}
    end
  end

  # Domain verification and DKIM sync hit DNS and the Haraka API, which can
  # take seconds — run them off the LiveView process so the UI stays responsive.
  def handle_event("verify_custom_domain", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_custom_domain(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Custom domain not found")}

      custom_domain ->
        {:noreply,
         socket
         |> assign(:domain_action_in_progress, custom_domain.id)
         |> start_async(:verify_custom_domain, fn ->
           Email.verify_custom_domain(custom_domain)
         end)}
    end
  end

  def handle_event("sync_custom_domain_dkim", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_custom_domain(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Custom domain not found")}

      custom_domain ->
        {:noreply,
         socket
         |> assign(:domain_action_in_progress, custom_domain.id)
         |> start_async(:sync_custom_domain_dkim, fn ->
           Email.sync_custom_domain_dkim(custom_domain)
         end)}
    end
  end

  def handle_event("delete_custom_domain", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_custom_domain(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Custom domain not found")}

      custom_domain ->
        case Email.delete_custom_domain(custom_domain) do
          {:ok, _deleted_domain} ->
            {:noreply,
             socket
             |> put_flash(:info, "Custom domain removed")
             |> assign_aliases_tab(user_id)}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               UserErrorHelpers.reason_message(
                 reason,
                 "Could not remove the custom domain right now."
               )
             )}
        end
    end
  end

  # Mailbox Forwarding Events

  def handle_event("update_mailbox_forwarding", %{"mailbox" => mailbox_params}, socket) do
    mailbox = socket.assigns.mailbox

    mailbox_params = Map.put_new(mailbox_params, "forward_enabled", "false")

    mailbox_params =
      if mailbox_params["forward_enabled"] == "true" do
        mailbox_params
      else
        Map.put(mailbox_params, "forward_to", nil)
      end

    case Email.update_mailbox_forwarding(mailbox, mailbox_params) do
      {:ok, updated_mailbox} ->
        {:noreply,
         socket
         |> put_flash(:info, "Main mailbox forwarding updated")
         |> assign(:mailbox, updated_mailbox)
         |> assign(:mailbox_form, to_form(Email.change_mailbox_forwarding(updated_mailbox)))}

      {:error, changeset} ->
        error = get_changeset_error(changeset)

        {:noreply,
         socket
         |> put_flash(:error, "Failed to update mailbox forwarding: #{error}")
         |> assign(:mailbox_form, to_form(changeset))}
    end
  end

  # Async result processing (delegated from the LiveView's handle_async/3)

  def handle_async(:verify_custom_domain, {:ok, result}, socket) do
    user_id = socket.assigns.current_user.id
    socket = assign(socket, :domain_action_in_progress, nil)

    case result do
      {:ok, %{status: "verified"}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Custom domain verified")
         |> assign_aliases_tab(user_id)}

      {:ok, pending_domain} ->
        error_message =
          pending_domain.last_error ||
            "Verification DNS records not found yet. Check DNS and try again."

        {:noreply,
         socket
         |> put_flash(:error, error_message)
         |> assign_aliases_tab(user_id)}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           UserErrorHelpers.reason_message(
             reason,
             "Could not verify the custom domain right now."
           )
         )}
    end
  end

  def handle_async(:verify_custom_domain, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:domain_action_in_progress, nil)
     |> put_flash(:error, "Could not verify the custom domain right now.")}
  end

  def handle_async(:sync_custom_domain_dkim, {:ok, result}, socket) do
    user_id = socket.assigns.current_user.id
    socket = assign(socket, :domain_action_in_progress, nil)

    case result do
      {:ok, synced_domain} ->
        flash_type = if synced_domain.dkim_last_error, do: :error, else: :info

        flash_message =
          if synced_domain.dkim_last_error do
            "DKIM sync failed: #{synced_domain.dkim_last_error}"
          else
            "DKIM synced to Haraka"
          end

        {:noreply,
         socket
         |> put_flash(flash_type, flash_message)
         |> assign_aliases_tab(user_id)}
    end
  end

  def handle_async(:sync_custom_domain_dkim, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:domain_action_in_progress, nil)
     |> put_flash(:error, "Could not sync DKIM right now.")}
  end

  # Private helpers

  defp normalize_alias_create_params(%{"alias" => params}) when is_map(params), do: params

  defp normalize_alias_create_params(%{"type" => "create_alias", "value" => params})
       when is_map(params),
       do: params

  defp normalize_alias_create_params(params) when is_map(params), do: params

  defp assign_aliases_tab(socket, user_id) do
    mailbox = Email.get_user_mailbox(user_id) || socket.assigns.mailbox

    socket
    |> assign(:mailbox, mailbox)
    |> assign(:mailbox_addresses, mailbox_addresses(mailbox, socket.assigns.current_user))
    |> assign(:mailbox_form, to_form(Email.change_mailbox_forwarding(mailbox)))
    |> assign(:aliases, Aliases.list_aliases(user_id))
    |> assign(:custom_domains, Email.list_user_custom_domains(user_id))
    |> assign(
      :available_email_domains,
      Elektrine.Domains.available_email_domains_for_user(socket.assigns.current_user)
    )
    |> assign(:new_alias, %Alias{})
  end

  # Render functions

  def render_aliases_tab(assigns) do
    ~H"""
    <div>
      <div class="mb-4">
        <h2 class="text-xl font-semibold">Email Aliases</h2>
        <p class="mt-1 text-base-content/70">
          Create additional email addresses that deliver to your mailbox or forward elsewhere. You can have up to 15 aliases.
        </p>
      </div>

      <form phx-submit="create_custom_domain" class="card space-y-4 mb-8 p-5">
        <div>
          <h3 class="font-semibold text-lg mb-1">Custom Domains</h3>
          <p class="text-sm text-base-content/60">
            Bring your own domain and route
            <span class="font-mono text-base-content">{@current_user.username}@your-domain.com</span>
            into this mailbox.
          </p>
        </div>

        <div>
          <label class="label pb-1">
            <span class="label-text font-medium">Domain</span>
          </label>

          <div class="flex flex-col gap-2 sm:flex-row">
            <input
              type="text"
              name="domain"
              placeholder="mail.example.com"
              class="input input-bordered sm:flex-1"
              required
            />

            <button type="submit" class="btn btn-secondary sm:self-start">Add Domain</button>
          </div>
        </div>

        <%= if Enum.empty?(@custom_domains) do %>
          <div class="text-center py-8 bg-base-200/30 rounded-lg border border-dashed border-base-content/20">
            <.icon name="hero-globe-alt" class="w-10 h-10 mx-auto text-base-content/30 mb-3" />
            <p class="text-base-content/50">No custom domains added yet</p>
            <p class="text-sm text-base-content/40 mt-1">
              Add one above to generate DNS records and a verification target.
            </p>
          </div>
        <% else %>
          <div class="space-y-3">
            <%= for custom_domain <- @custom_domains do %>
              <div class="card p-4">
                <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                  <div class="min-w-0 flex-1">
                    <div class="min-w-0">
                      <div class="flex flex-wrap items-center gap-2">
                        <h4 class="truncate text-base font-semibold tracking-tight">
                          {custom_domain.domain}
                        </h4>
                        <span class={[
                          "badge badge-sm border-0 font-medium",
                          custom_domain_status_badge(custom_domain.status)
                        ]}>
                          {String.capitalize(custom_domain.status)}
                        </span>
                      </div>

                      <div class="mt-2 text-xs font-medium text-base-content/50">Primary Address</div>
                      <div class="mt-1 flex items-start gap-2">
                        <div class="font-mono text-sm text-base-content/80 break-all flex-1">
                          {@current_user.username}@{custom_domain.domain}
                        </div>
                        <.copy_button
                          id={"email-domain-primary-address-#{custom_domain.id}"}
                          content={"#{@current_user.username}@#{custom_domain.domain}"}
                          label="Copy primary address"
                        />
                      </div>

                      <div class="mt-2 text-xs text-base-content/55">
                        <%= if custom_domain.status == "verified" do %>
                          TXT and MX verified.
                        <% else %>
                          Waiting for TXT and MX verification.
                        <% end %>
                      </div>
                    </div>

                    <%= if Elektrine.Strings.present?(custom_domain.last_error) do %>
                      <div class="mt-3 rounded-lg border border-error/20 bg-error/5 px-3 py-2 text-xs leading-5 text-error">
                        {custom_domain.last_error}
                      </div>
                    <% end %>

                    <div class="mt-4 rounded-lg border border-base-content/10 bg-base-100/50">
                      <div class="border-b border-base-content/10 px-4 py-3">
                        <div class="text-sm font-medium text-base-content/70">DNS Records</div>
                      </div>

                      <div class="divide-y divide-base-content/10">
                        <%= for {record, index} <-
                              Enum.with_index(Email.dns_records_for_custom_domain(custom_domain)) do %>
                          <div class="grid gap-3 px-4 py-3 sm:grid-cols-[88px_minmax(0,0.9fr)_minmax(0,1.4fr)]">
                            <div class="flex items-start sm:items-center">
                              <span class="badge badge-outline badge-sm font-medium">
                                {record.type}
                              </span>
                            </div>

                            <div class="min-w-0">
                              <div class="text-xs font-medium text-base-content/50">Host</div>
                              <div class="mt-1 flex items-start gap-2">
                                <div class="font-mono text-xs leading-5 text-base-content/80 break-all flex-1">
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
                              <div class="flex flex-wrap items-center gap-2 text-xs font-medium text-base-content/50">
                                <span>Value</span>
                                <%= if record.priority do %>
                                  <span class="rounded-full bg-base-200 px-2 py-0.5 normal-case tracking-normal text-base-content/65">
                                    priority {record.priority}
                                  </span>
                                <% end %>
                              </div>
                              <div class="mt-1 text-xs font-medium text-base-content/55">
                                {record.label}
                              </div>
                              <div class="mt-1 flex items-start gap-2">
                                <div class="font-mono text-xs leading-5 text-base-content/80 break-all flex-1">
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

                  <div class="flex w-full flex-col gap-2 xl:w-36 xl:shrink-0 xl:pt-0.5">
                    <%= if custom_domain.status != "verified" do %>
                      <button
                        type="button"
                        phx-click="verify_custom_domain"
                        phx-value-id={custom_domain.id}
                        class="btn btn-secondary btn-sm w-full justify-center"
                        disabled={@domain_action_in_progress == custom_domain.id}
                      >
                        <%= if @domain_action_in_progress == custom_domain.id do %>
                          <span class="loading loading-spinner loading-xs"></span>
                          <span>Verifying…</span>
                        <% else %>
                          <span>Verify</span>
                        <% end %>
                      </button>
                    <% end %>
                    <button
                      type="button"
                      phx-click="delete_custom_domain"
                      phx-value-id={custom_domain.id}
                      class="btn btn-ghost btn-sm w-full justify-center text-error hover:bg-error/10"
                      data-confirm="Remove this custom domain?"
                    >
                      <span>Delete</span>
                    </button>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </form>

      <.form
        for={@mailbox_form}
        as={:mailbox}
        phx-submit="update_mailbox_forwarding"
        class="card space-y-4 mb-8 p-5"
      >
        <h3 class="font-semibold text-lg mb-1">Main Email Forwarding</h3>
        <p class="text-sm text-base-content/60">
          Forward all emails sent to your primary mailbox addresses.
        </p>

        <div class="flex flex-wrap gap-2">
          <%= if @mailbox.username do %>
            <%= for domain <- @available_email_domains do %>
              <span class="badge badge-outline">{@mailbox.username}@{domain}</span>
            <% end %>
          <% else %>
            <span class="badge badge-outline">{@mailbox.email}</span>
          <% end %>
        </div>

        <div class="flex items-center justify-between p-3 bg-base-200/55 rounded-lg">
          <label class="label cursor-pointer gap-3 p-0">
            <span class="label-text font-medium">Enable Forwarding</span>
            <input type="hidden" name="mailbox[forward_enabled]" value="false" />
            <input
              type="checkbox"
              name="mailbox[forward_enabled]"
              value="true"
              checked={@mailbox.forward_enabled}
              class="toggle toggle-secondary"
            />
          </label>
        </div>

        <div>
          <label class="label pb-1">
            <span class="label-text font-medium">Forward to Email</span>
          </label>
          <input
            type="email"
            name="mailbox[forward_to]"
            value={@mailbox_form[:forward_to].value || ""}
            placeholder="your.email@example.com"
            class="input input-bordered w-full"
          />
          <div class="text-xs text-base-content/50 mt-1">
            Required when forwarding is enabled.
          </div>
        </div>

        <%= if @mailbox.forward_enabled && Elektrine.Strings.present?(@mailbox.forward_to) do %>
          <div class="alert alert-info py-2 px-3">
            <span class="text-sm">
              Forwarding active: mail to your main mailbox goes to {@mailbox.forward_to}
            </span>
          </div>
        <% end %>

        <div class="flex justify-end">
          <button type="submit" class="btn btn-secondary">Save Main Forwarding</button>
        </div>
      </.form>
      
    <!-- Add Form -->
      <form phx-submit="create_alias" class="card space-y-4 mb-8 p-5">
        <h3 class="font-semibold text-lg mb-4">Create New Alias</h3>
        
    <!-- Alias Address Row -->
        <div>
          <label class="label pb-1">
            <span class="label-text font-medium">Alias Address</span>
          </label>
          <div class="flex items-center gap-2">
            <input
              type="text"
              name="username"
              placeholder="myalias"
              class="input input-bordered min-w-0 flex-1 font-sans"
              pattern="[a-zA-Z0-9]+"
              title="Only letters and numbers allowed"
              minlength="4"
              maxlength="30"
              required
            />
            <span class="shrink-0 text-base-content/50">@</span>
            <select
              name="domain"
              class="select select-bordered max-w-[45vw] shrink-0 font-sans sm:max-w-none"
            >
              <%= for domain <- @available_email_domains do %>
                <option value={domain}>{domain}</option>
              <% end %>
            </select>
          </div>
          <div class="text-xs text-base-content/50 mt-1">
            4-30 characters, letters and numbers only
          </div>
        </div>
        
    <!-- Forward To Row -->
        <div>
          <label class="label pb-1">
            <span class="label-text font-medium">Forward To (optional)</span>
          </label>
          <input
            type="email"
            name="target_email"
            placeholder="your.personal@gmail.com"
            class="input input-bordered w-full font-sans"
          />
          <div class="text-xs text-base-content/50 mt-1">
            Leave empty to deliver emails to your main mailbox
          </div>
        </div>
        
    <!-- Description Row -->
        <div>
          <label class="label pb-1">
            <span class="label-text font-medium">Description (optional)</span>
          </label>
          <input
            type="text"
            name="description"
            placeholder="e.g., Shopping accounts, newsletters, work stuff..."
            class="input input-bordered w-full font-sans"
            maxlength="500"
          />
        </div>
        <div class="flex justify-end">
          <button type="submit" class="btn btn-secondary">Create Alias</button>
        </div>
      </form>
      
    <!-- List -->
      <%= if !Enum.empty?(@aliases) do %>
        <h3 class="font-semibold text-lg mb-3">Your Aliases</h3>
      <% end %>
      <div class="space-y-3">
        <%= for alias_record <- @aliases do %>
          <div class="card p-4">
            <div class="flex items-start justify-between gap-4">
              <div class="flex items-start gap-4 flex-1">
                <label class="swap cursor-pointer mt-0.5">
                  <input
                    type="checkbox"
                    checked={alias_record.enabled}
                    phx-click="toggle_alias"
                    phx-value-id={alias_record.id}
                  />
                  <div class="swap-on">
                    <.icon name="hero-check-circle-solid" class="w-6 h-6 text-success" />
                  </div>
                  <div class="swap-off">
                    <.icon name="hero-x-circle-solid" class="w-6 h-6 text-base-content/30" />
                  </div>
                </label>
                <div class="flex-1 min-w-0">
                  <div class="flex flex-col sm:flex-row sm:items-center gap-1 sm:gap-3">
                    <span class="font-semibold text-lg">{alias_record.alias_email}</span>
                    <%= if Elektrine.Strings.present?(alias_record.target_email) do %>
                      <div class="flex items-center gap-2 text-base-content/60">
                        <.icon name="hero-arrow-right" class="w-4 h-4" />
                        <span class="text-sm">{alias_record.target_email}</span>
                      </div>
                    <% else %>
                      <span class="badge badge-ghost gap-1">
                        <.icon name="hero-inbox" class="w-3 h-3" /> Main Mailbox
                      </span>
                    <% end %>
                  </div>
                  <%= if Elektrine.Strings.present?(alias_record.description) do %>
                    <p class="text-sm text-base-content/50 mt-1">{alias_record.description}</p>
                  <% end %>
                  <%= if !alias_record.enabled do %>
                    <div class="mt-2">
                      <span class="badge badge-sm badge-warning gap-1">
                        <.icon name="hero-pause" class="w-3 h-3" /> Disabled
                      </span>
                    </div>
                  <% end %>
                </div>
              </div>
              <button
                phx-click="delete_alias"
                phx-value-id={alias_record.id}
                class="btn btn-ghost btn-sm text-error hover:bg-error/10"
                data-confirm="Are you sure you want to delete this alias?"
              >
                <.icon name="hero-trash" class="w-4 h-4" />
              </button>
            </div>
          </div>
        <% end %>
        <%= if Enum.empty?(@aliases) do %>
          <div class="text-center py-12 bg-base-200/30 rounded-lg border border-dashed border-base-content/20">
            <.icon name="hero-at-symbol" class="w-12 h-12 mx-auto text-base-content/30 mb-3" />
            <p class="text-base-content/50">No aliases created yet</p>
            <p class="text-sm text-base-content/40 mt-1">Create your first alias above</p>
          </div>
        <% end %>
      </div>
      
    <!-- Info -->
      <div class="card mt-6 p-4">
        <div class="flex gap-3">
          <.icon name="hero-information-circle" class="h-5 w-5 text-info flex-shrink-0 mt-0.5" />
          <div class="text-sm">
            <p class="font-medium text-info">How aliases work</p>
            <p class="text-base-content/70 mt-1">
              Emails sent to your aliases will be delivered to your main mailbox unless you specify a forwarding address.
              You can disable an alias to stop receiving emails without deleting it.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

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

  defp custom_domain_status_badge("verified"), do: "badge-success text-success-content"
  defp custom_domain_status_badge(_), do: "badge-warning text-warning-content"
end
