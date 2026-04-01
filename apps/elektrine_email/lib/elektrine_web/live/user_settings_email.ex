defmodule ElektrineWeb.UserSettingsEmail do
  @moduledoc """
  Email-owned helpers for the shared account settings shell.
  """

  use ElektrineEmailWeb, :html

  import ElektrineWeb.Live.NotificationHelpers

  alias Elektrine.Accounts
  alias Elektrine.Email
  alias Elektrine.Email.ListTypes
  alias Elektrine.Email.Mailbox
  alias Elektrine.Email.PGP
  alias Elektrine.Email.Unsubscribes

  def init_assigns(socket) do
    socket
    |> assign(:loading_email, true)
    |> assign(:mailboxes, [])
    |> assign(:primary_mailbox, nil)
    |> assign(:aliases, [])
    |> assign(:user_emails, [])
    |> assign(:lists, [])
    |> assign(:lists_by_type, %{})
    |> assign(:has_subscribable_lists, false)
    |> assign(:unsubscribe_status, %{})
    |> assign(:private_mailbox_configured, false)
    |> assign(:private_mailbox_enabled, false)
    |> assign(:private_mailbox_public_key, nil)
    |> assign(:private_mailbox_wrapped_private_key, nil)
    |> assign(:private_mailbox_verifier, nil)
    |> assign(:private_mailbox_unlock_mode, "account_password")
  end

  def load_profile_data(socket) do
    user = socket.assigns.user
    mailboxes_task = Task.async(fn -> Email.get_user_mailboxes(user.id) end)
    aliases_task = Task.async(fn -> Email.list_aliases(user.id) end)
    mailboxes = Task.await(mailboxes_task)
    aliases = Task.await(aliases_task)

    user_emails =
      (Elektrine.Domains.email_addresses_for_user(user) ++ Enum.map(aliases, & &1.alias_email))
      |> Enum.uniq()

    socket
    |> assign(:mailboxes, mailboxes)
    |> assign(:aliases, aliases)
    |> assign(:user_emails, user_emails)
    |> assign(:loading_profile, false)
  end

  def load_email_data(socket) do
    user = socket.assigns.user
    lists_task = Task.async(fn -> ListTypes.active_lists() end)
    lists_by_type_task = Task.async(fn -> ListTypes.active_lists_by_type() end)
    mailboxes_task = Task.async(fn -> Email.get_user_mailboxes(user.id) end)
    aliases_task = Task.async(fn -> Email.list_aliases(user.id) end)
    lists = Task.await(lists_task)
    lists_by_type = Task.await(lists_by_type_task)
    mailboxes = Task.await(mailboxes_task)
    aliases = Task.await(aliases_task)

    user_emails =
      (Elektrine.Domains.email_addresses_for_user(user) ++ Enum.map(aliases, & &1.alias_email))
      |> Enum.uniq()

    list_ids = Enum.map(lists, & &1.id)
    unsubscribe_status = Unsubscribes.batch_check_unsubscribed(user_emails, list_ids)
    primary_mailbox = Enum.find(mailboxes, &(&1.user_id == user.id)) || List.first(mailboxes)

    socket
    |> assign(:lists, lists)
    |> assign(:lists_by_type, lists_by_type)
    |> assign(:has_subscribable_lists, Enum.any?(lists, & &1.can_unsubscribe))
    |> assign(:mailboxes, mailboxes)
    |> assign(:primary_mailbox, primary_mailbox)
    |> assign(:aliases, aliases)
    |> assign(:user_emails, user_emails)
    |> assign(:unsubscribe_status, unsubscribe_status)
    |> assign_private_mailbox_state(primary_mailbox)
    |> assign(:loading_email, false)
  end

  def handle_event("toggle_subscription", %{"list_id" => list_id}, socket) do
    any_subscribed =
      Enum.any?(socket.assigns.user_emails, fn email ->
        !Unsubscribes.unsubscribed?(email, list_id)
      end)

    action =
      if any_subscribed do
        Enum.each(socket.assigns.user_emails, fn email ->
          Unsubscribes.unsubscribe(email,
            list_id: list_id,
            user_id: socket.assigns.current_user.id
          )
        end)

        "Unsubscribed from"
      else
        Enum.each(socket.assigns.user_emails, fn email ->
          Unsubscribes.resubscribe(email, list_id)
        end)

        "Resubscribed to"
      end

    list_ids = Enum.map(socket.assigns.lists, & &1.id)

    unsubscribe_status =
      Unsubscribes.batch_check_unsubscribed(socket.assigns.user_emails, list_ids)

    list_name = ListTypes.get_name(list_id)

    {:handled,
     socket
     |> assign(:unsubscribe_status, unsubscribe_status)
     |> notify_info("#{action} #{list_name} for all addresses")}
  end

  def handle_event("unsubscribe_all", %{"email" => email}, socket) do
    Enum.each(socket.assigns.lists, fn list ->
      Unsubscribes.unsubscribe(email, list_id: list.id, user_id: socket.assigns.current_user.id)
    end)

    list_ids = Enum.map(socket.assigns.lists, & &1.id)

    unsubscribe_status =
      Unsubscribes.batch_check_unsubscribed(socket.assigns.user_emails, list_ids)

    {:handled,
     socket
     |> assign(:unsubscribe_status, unsubscribe_status)
     |> notify_info("Unsubscribed from all mailing lists")}
  end

  def handle_event("resubscribe_all", %{"email" => email}, socket) do
    Enum.each(socket.assigns.lists, fn list -> Unsubscribes.resubscribe(email, list.id) end)
    list_ids = Enum.map(socket.assigns.lists, & &1.id)

    unsubscribe_status =
      Unsubscribes.batch_check_unsubscribed(socket.assigns.user_emails, list_ids)

    {:handled,
     socket
     |> assign(:unsubscribe_status, unsubscribe_status)
     |> notify_info("Resubscribed to all mailing lists")}
  end

  def handle_event("upload_pgp_key", %{"pgp_public_key" => key_text}, socket) do
    user = socket.assigns.user

    case PGP.store_user_key(user, key_text) do
      {:ok, updated_user} ->
        {:handled,
         socket
         |> assign(:user, updated_user)
         |> assign(:changeset, Accounts.change_user(updated_user, %{}))
         |> notify_info("PGP key uploaded successfully")}

      {:error, reason}
      when reason in [:not_pgp_key, :invalid_base64, :parse_error, :invalid_input] ->
        {:handled,
         socket
         |> notify_error("Invalid PGP key format. Please paste a valid ASCII-armored public key.")}

      {:error, _reason} ->
        {:handled, socket |> notify_error("Failed to upload PGP key. Please try again.")}
    end
  end

  def handle_event("delete_pgp_key", _params, socket) do
    user = socket.assigns.user

    case PGP.delete_user_key(user) do
      {:ok, updated_user} ->
        {:handled,
         socket
         |> assign(:user, updated_user)
         |> assign(:changeset, Accounts.change_user(updated_user, %{}))
         |> notify_info("PGP key removed")}

      {:error, _reason} ->
        {:handled, socket |> notify_error("Failed to remove PGP key")}
    end
  end

  def handle_event("private_mailbox_setup", %{"private_mailbox" => params}, socket) do
    mailbox = socket.assigns.primary_mailbox
    current_user = socket.assigns.current_user

    with mailbox when not is_nil(mailbox) <- mailbox,
         {:ok, decoded_params} <- decode_private_mailbox_setup_params(params),
         :ok <- verify_private_mailbox_setup_password_mode(current_user, decoded_params),
         {:ok, updated_mailbox} <-
           Email.update_mailbox_private_storage(mailbox, %{
             private_storage_enabled: true,
             private_storage_public_key: decoded_params["public_key"],
             private_storage_wrapped_private_key: decoded_params["wrapped_private_key"],
             private_storage_verifier: decoded_params["verifier"]
           }) do
      {:handled,
       socket
       |> assign(:primary_mailbox, updated_mailbox)
       |> assign_private_mailbox_state(updated_mailbox)
       |> notify_info("Private mailbox storage enabled")}
    else
      nil ->
        {:handled, notify_error(socket, "Mailbox not found")}

      {:error, :invalid_payload} ->
        {:handled,
         notify_error(
           socket,
           "Private mailbox setup payload is invalid. Generate it in the browser and try again."
         )}

      {:error, :invalid_account_password} ->
        {:handled,
         notify_error(
           socket,
           "Your current account password was incorrect, so private mailbox storage was not enabled."
         )}

      {:error, changeset} ->
        {:handled, notify_error(socket, private_mailbox_changeset_error(changeset))}
    end
  end

  def handle_event("enable_private_mailbox", _params, socket) do
    mailbox = socket.assigns.primary_mailbox

    if mailbox && Mailbox.private_storage_configured?(mailbox) do
      case Email.update_mailbox_private_storage(mailbox, %{private_storage_enabled: true}) do
        {:ok, updated_mailbox} ->
          {:handled,
           socket
           |> assign(:primary_mailbox, updated_mailbox)
           |> assign_private_mailbox_state(updated_mailbox)
           |> notify_info("Private mailbox storage resumed")}

        {:error, _changeset} ->
          {:handled, notify_error(socket, "Failed to enable private mailbox storage")}
      end
    else
      {:handled, notify_error(socket, "Set up a private mailbox key before enabling storage")}
    end
  end

  def handle_event("disable_private_mailbox", _params, socket) do
    mailbox = socket.assigns.primary_mailbox

    if mailbox && Mailbox.private_storage_configured?(mailbox) do
      case Email.update_mailbox_private_storage(mailbox, %{private_storage_enabled: false}) do
        {:ok, updated_mailbox} ->
          {:handled,
           socket
           |> assign(:primary_mailbox, updated_mailbox)
           |> assign_private_mailbox_state(updated_mailbox)
           |> notify_info("Private mailbox storage paused")}

        {:error, _changeset} ->
          {:handled, notify_error(socket, "Failed to pause private mailbox storage")}
      end
    else
      {:handled, socket}
    end
  end

  def profile_summary(assigns) do
    ~H"""
    <div class="bg-base-200 rounded-lg p-4 space-y-2">
      <%= if @mailboxes && @mailboxes != [] do %>
        <%= for mailbox <- @mailboxes do %>
          <div class="flex items-center justify-between">
            <span class="text-sm font-medium">{gettext("Primary Email")}</span>
            <span class="text-sm font-medium">{mailbox.email}</span>
          </div>
        <% end %>
      <% end %>

      <%= if @aliases && @aliases != [] do %>
        <div class="flex items-center justify-between">
          <span class="text-sm font-medium">{gettext("Email Aliases")}</span>
          <span class="text-sm">
            {gettext("%{count} configured", count: length(@aliases))}
          </span>
        </div>
      <% else %>
        <div class="flex items-center justify-between">
          <span class="text-sm font-medium">{gettext("Email Aliases")}</span>
          <span class="text-sm text-base-content/70">
            {gettext("None configured")}
          </span>
        </div>
      <% end %>

      <div class="text-xs text-base-content/60 mt-2">
        {gettext("Manage email addresses and aliases in the")}
        <.link href={~p"/email"} class="link link-primary">
          {gettext("Email section")}
        </.link>
      </div>
    </div>
    """
  end

  def email_tab(assigns) do
    ~H"""
    <div class="card panel-card">
      <div class="card-body p-4 sm:p-6">
        <h3 class="card-title text-base sm:text-lg flex items-center gap-2">
          <.icon name="hero-envelope" class="w-5 h-5" /> {gettext("Email Settings")}
        </h3>

        <.form
          for={@changeset}
          id="email-form"
          phx-submit="save"
          phx-change="validate"
          class="space-y-4"
        >
          <div class="bg-base-200 rounded-lg p-4 space-y-2">
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium">{gettext("Username")}</span>
              <span class="text-sm font-medium">{@user.username}</span>
            </div>
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium">{gettext("Unique ID")}</span>
              <span class="text-sm font-medium text-base-content/70">
                {@user.unique_id}
              </span>
            </div>
            <div class="text-xs text-base-content/60 mt-2">
              {gettext(
                "Username is for login only. Your handle (%{handle}) is your public identity.",
                handle: @user.handle
              )}
            </div>
          </div>

          <.profile_summary {assigns} />

          <div class="divider text-sm my-4">{gettext("Default Email Domain")}</div>

          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">{gettext("Compose From")}</span>
            </label>
            <select
              name="user[preferred_email_domain]"
              class="select select-bordered w-full"
            >
              <%= for domain <- Elektrine.Domains.available_email_domains_for_user(@user) do %>
                <option
                  value={domain}
                  selected={
                    (@user.preferred_email_domain ||
                       Elektrine.Domains.default_user_handle_domain()) ==
                      domain
                  }
                >
                  {@user.username}@{domain}
                </option>
              <% end %>
            </select>
            <label class="label">
              <span class="label-text-alt">
                {gettext("Default 'From' address when composing new emails")}
              </span>
            </label>
          </div>

          <div class="divider text-sm my-4">{gettext("Email Signature")}</div>

          <div>
            <label class="label">
              <span class="label-text font-medium">{gettext("Signature")}</span>
              <span class="label-text-alt text-xs">{gettext("Max 500 characters")}</span>
            </label>
            <textarea
              name="user[email_signature]"
              rows="4"
              class="textarea textarea-bordered w-full text-sm"
              maxlength="500"
              placeholder={
                gettext(
                  "Your signature will be automatically appended to outgoing emails.\n\nExample:\nBest regards,\nYour Name\nYour Title"
                )
              }
            ><%= Ecto.Changeset.get_field(@changeset, :email_signature) %></textarea>
            <div class="label">
              <span class="text-xs text-base-content/60">
                {gettext("Automatically appended to all outgoing emails with '-- ' separator")}
              </span>
            </div>
          </div>

          <div class="card-actions justify-end">
            <.button class="btn-primary btn-sm w-full sm:w-auto text-xs sm:text-sm">
              {gettext("Save Settings")}
            </.button>
          </div>
        </.form>
      </div>
    </div>

    <div
      id="private-mailbox-settings"
      phx-hook="MailboxPrivateStorage"
      class="card panel-card"
      data-private-mailbox-configured={to_string(@private_mailbox_configured)}
      data-private-mailbox-enabled={to_string(@private_mailbox_enabled)}
      data-private-mailbox-unlock-mode={@private_mailbox_unlock_mode}
      data-private-mailbox-id={@primary_mailbox && @primary_mailbox.id}
      data-private-mailbox-wrapped-key={encode_payload(@private_mailbox_wrapped_private_key)}
      data-private-mailbox-verifier={encode_payload(@private_mailbox_verifier)}
    >
      <div class="card-body p-4 sm:p-6">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h3 class="card-title text-base sm:text-lg flex items-center gap-2">
              <.icon name="hero-shield-check" class="w-5 h-5" />
              {gettext("Private Mailbox Storage")}
            </h3>
            <p class="text-xs sm:text-sm text-base-content/70 mt-1">
              {gettext(
                "Store protected email with a browser-generated mailbox key. By default, the key is wrapped with your account password so the mailbox can unlock after password login."
              )}
            </p>
          </div>

          <div class={[
            "badge",
            if(@private_mailbox_enabled, do: "badge-success", else: "badge-outline")
          ]}>
            <%= if @private_mailbox_enabled do %>
              {gettext("Active")}
            <% else %>
              {gettext("Inactive")}
            <% end %>
          </div>
        </div>

        <%= if @primary_mailbox do %>
          <div class="grid grid-cols-1 xl:grid-cols-2 gap-4 sm:gap-6 mt-4">
            <div class="rounded-lg border border-base-300 bg-base-200/55 p-4 space-y-4">
              <%= if @private_mailbox_configured do %>
                <div>
                  <h4 class="font-semibold text-sm">{gettext("Unlock Mailbox")}</h4>
                  <p class="text-xs text-base-content/70 mt-1" data-private-mailbox-locked-content>
                    <%= if @private_mailbox_unlock_mode == "account_password" do %>
                      {gettext(
                        "This mailbox uses your account password by default. Password logins can unlock it automatically in this tab, and passkey or remembered sessions can unlock it with your account password."
                      )}
                    <% else %>
                      {gettext(
                        "Unlock once per browser tab with your separate mailbox passphrase to view protected message content."
                      )}
                    <% end %>
                  </p>
                </div>

                <div class="space-y-3" data-private-mailbox-locked-content>
                  <input
                    type="password"
                    class="input input-bordered w-full"
                    placeholder={
                      if @private_mailbox_unlock_mode == "account_password",
                        do: gettext("Enter account password"),
                        else: gettext("Enter mailbox passphrase")
                    }
                    autocomplete="current-password"
                    data-private-mailbox-passphrase
                  />

                  <div class="flex flex-col sm:flex-row gap-2">
                    <button
                      type="button"
                      class="btn btn-primary btn-sm flex-1"
                      data-private-mailbox-unlock
                    >
                      {gettext("Unlock")}
                    </button>
                  </div>

                  <p class="text-xs text-base-content/70" data-private-mailbox-status>
                    {gettext("Mailbox locked.")}
                  </p>
                </div>

                <div
                  class="hidden rounded-lg border border-success/30 bg-success/10 p-3"
                  data-private-mailbox-unlocked-content
                >
                  <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                    <p class="text-sm text-base-content/80" data-private-mailbox-status>
                      {gettext("Mailbox unlocked in this tab.")}
                    </p>
                    <button
                      type="button"
                      class="btn btn-outline btn-sm"
                      data-private-mailbox-lock
                    >
                      {gettext("Lock")}
                    </button>
                  </div>
                </div>

                <div class="divider my-2"></div>

                <div class="flex flex-col sm:flex-row gap-2">
                  <%= if @private_mailbox_enabled do %>
                    <button
                      type="button"
                      phx-click="disable_private_mailbox"
                      class="btn btn-outline btn-sm flex-1"
                    >
                      {gettext("Pause Protection")}
                    </button>
                  <% else %>
                    <button
                      type="button"
                      phx-click="enable_private_mailbox"
                      class="btn btn-primary btn-sm flex-1"
                    >
                      {gettext("Resume Protection")}
                    </button>
                  <% end %>
                </div>
              <% else %>
                <div>
                  <h4 class="font-semibold text-sm">{gettext("Set Up Private Mailbox")}</h4>
                  <p class="text-xs text-base-content/70 mt-1">
                    {gettext(
                      "Generate a mailbox keypair in this browser, then choose whether to wrap it with your account password or a separate mailbox passphrase."
                    )}
                  </p>
                </div>

                <.form for={%{}} phx-submit="private_mailbox_setup" data-private-mailbox-setup-form>
                  <div class="space-y-3">
                    <div class="space-y-2">
                      <label class="label py-0">
                        <span class="label-text text-xs uppercase tracking-wide text-base-content/60">
                          {gettext("Unlock method")}
                        </span>
                      </label>
                      <select
                        name="private_mailbox[unlock_mode]"
                        class="select select-bordered w-full"
                        data-private-mailbox-setup-mode
                      >
                        <option value="account_password" selected>
                          {gettext("Use account password")}
                        </option>
                        <option value="separate_passphrase">
                          {gettext("Use separate mailbox passphrase")}
                        </option>
                      </select>
                    </div>

                    <div class="space-y-3" data-private-mailbox-account-password-fields>
                      <input
                        type="password"
                        name="private_mailbox[current_account_password]"
                        class="input input-bordered w-full"
                        placeholder={gettext("Current account password")}
                        autocomplete="current-password"
                        data-private-mailbox-account-password
                      />
                      <p class="text-xs text-base-content/60">
                        {gettext(
                          "Recommended. This makes password login the default unlock path. Passkey and remembered sessions can still unlock manually with your account password."
                        )}
                      </p>
                    </div>

                    <div
                      class="space-y-3 hidden"
                      data-private-mailbox-custom-passphrase-fields
                    >
                      <input
                        type="password"
                        name="_private_mailbox_passphrase"
                        class="input input-bordered w-full"
                        placeholder={gettext("New mailbox passphrase")}
                        autocomplete="new-password"
                        data-private-mailbox-setup-passphrase
                      />
                      <input
                        type="password"
                        name="_private_mailbox_passphrase_confirm"
                        class="input input-bordered w-full"
                        placeholder={gettext("Confirm passphrase")}
                        autocomplete="new-password"
                        data-private-mailbox-setup-passphrase-confirm
                      />
                      <p class="text-xs text-base-content/60">
                        {gettext(
                          "Choose this only if you want mailbox unlock to stay separate from account login."
                        )}
                      </p>
                    </div>

                    <input
                      type="hidden"
                      name="private_mailbox[wrapped_private_key]"
                      data-private-mailbox-wrapped-key-input
                    />
                    <input
                      type="hidden"
                      name="private_mailbox[public_key]"
                      data-private-mailbox-public-key-input
                    />
                    <input
                      type="hidden"
                      name="private_mailbox[verifier]"
                      data-private-mailbox-verifier-input
                    />

                    <button
                      type="button"
                      class="btn btn-primary btn-sm w-full"
                      data-private-mailbox-setup-submit
                    >
                      {gettext("Enable Private Storage")}
                    </button>
                  </div>
                </.form>
              <% end %>
            </div>

            <div class="rounded-lg border border-base-300 bg-base-200/55 p-4">
              <h4 class="font-semibold text-sm mb-3">{gettext("What is protected")}</h4>
              <ul class="list-disc list-inside space-y-2 text-xs sm:text-sm text-base-content/70">
                <li>
                  {gettext("Stored message subjects, bodies, and attachments are encrypted at rest.")}
                </li>
                <li>
                  {gettext(
                    "The browser unlocks content locally after password login or after you enter the mailbox unlock secret in this tab."
                  )}
                </li>
                <li>
                  {gettext("Search previews stay generic until you unlock the mailbox in this tab.")}
                </li>
                <li>
                  {gettext(
                    "Normal SMTP headers like From, To, CC, and BCC are still stored as standard metadata."
                  )}
                </li>
              </ul>
            </div>
          </div>
        <% else %>
          <div class="alert alert-info mt-4">
            <.icon name="hero-information-circle" class="w-5 h-5" />
            <span class="text-sm">
              {gettext("Create a mailbox first before enabling private storage.")}
            </span>
          </div>
        <% end %>
      </div>
    </div>

    <div class="card panel-card">
      <div class="card-body p-4 sm:p-6">
        <h3 class="card-title text-base sm:text-lg flex items-center gap-2">
          <.icon name="hero-lock-closed" class="w-5 h-5" /> {gettext("PGP Encryption")}
        </h3>
        <p class="text-xs sm:text-sm text-base-content/70 mb-4">
          {gettext(
            "Upload your PGP public key to enable encrypted email. Recipients can discover your key via WKD."
          )}
        </p>

        <%= if @user.pgp_public_key do %>
          <div class="bg-base-200 rounded-lg p-4 space-y-3 mb-4">
            <div class="flex items-center gap-2">
              <.icon name="hero-key" class="w-5 h-5 text-success" />
              <span class="font-medium text-success text-sm">
                {gettext("PGP Key Active")}
              </span>
            </div>

            <%= if @user.pgp_fingerprint do %>
              <div>
                <div class="text-xs text-base-content/60 mb-1">
                  {gettext("Fingerprint")}
                </div>
                <code class="text-xs font-mono bg-base-300 px-2 py-1 rounded block break-all">
                  {format_fingerprint(@user.pgp_fingerprint)}
                </code>
              </div>
            <% end %>

            <%= if @user.pgp_key_id do %>
              <div>
                <div class="text-xs text-base-content/60 mb-1">{gettext("Key ID")}</div>
                <code class="text-xs font-mono bg-base-300 px-2 py-1 rounded">
                  {@user.pgp_key_id}
                </code>
              </div>
            <% end %>

            <%= if @user.pgp_key_uploaded_at do %>
              <div>
                <div class="text-xs text-base-content/60 mb-1">{gettext("Uploaded")}</div>
                <span class="text-xs">
                  {Calendar.strftime(@user.pgp_key_uploaded_at, "%Y-%m-%d %H:%M UTC")}
                </span>
              </div>
            <% end %>
          </div>

          <div class="bg-base-200 rounded-lg p-4 mb-4">
            <div class="text-xs text-base-content/60 mb-1">
              {gettext("WKD Discovery URL")}
            </div>
            <code class="text-xs font-mono break-all">
              https://{Elektrine.Domains.default_user_handle_domain()}/.well-known/openpgpkey/hu/{wkd_hash(
                @user.username
              )}
            </code>
            <div class="text-xs text-base-content/50 mt-2">
              {gettext("Email clients can automatically discover your key at this URL.")}
            </div>
          </div>

          <div class="card-actions">
            <button
              type="button"
              phx-click="delete_pgp_key"
              data-confirm={
                gettext(
                  "Are you sure you want to remove your PGP key? This will disable encrypted email."
                )
              }
              class="btn btn-error btn-sm w-full"
            >
              <.icon name="hero-trash" class="w-4 h-4" />
              {gettext("Remove PGP Key")}
            </button>
          </div>
        <% else %>
          <.form for={%{}} id="pgp-key-form" phx-submit="upload_pgp_key" class="space-y-4">
            <div>
              <label class="label">
                <span class="label-text font-medium">{gettext("Public Key")}</span>
              </label>
              <textarea
                name="pgp_public_key"
                rows="8"
                class="textarea textarea-bordered w-full font-mono text-xs"
                placeholder="-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n...\n\n-----END PGP PUBLIC KEY BLOCK-----"
                required
              ></textarea>
              <div class="label">
                <span class="text-xs text-base-content/60">
                  {gettext("Paste your ASCII-armored PGP public key.")}
                </span>
              </div>
            </div>

            <div class="card-actions">
              <.button class="btn-primary btn-sm w-full">
                <.icon name="hero-arrow-up-tray" class="w-4 h-4" />
                {gettext("Upload Public Key")}
              </.button>
            </div>
          </.form>

          <div class="alert alert-info mt-4">
            <.icon name="hero-information-circle" class="w-5 h-5" />
            <div class="text-xs">
              <div class="font-medium mb-1">{gettext("How it works")}</div>
              <ul class="list-disc list-inside space-y-1">
                <li>
                  {gettext("When you send an email, we check if the recipient has a PGP key")}
                </li>
                <li>
                  {gettext("Keys are discovered via WKD (Web Key Directory) or your contacts")}
                </li>
                <li>
                  {gettext("If a key is found, the email body is encrypted automatically")}
                </li>
              </ul>
            </div>
          </div>
        <% end %>
      </div>
    </div>

    <%= if @loading_email do %>
      <div class="card panel-card">
        <div class="card-body p-4 sm:p-6">
          <h3 class="card-title text-base sm:text-lg flex items-center gap-2 mb-4">
            <.icon name="hero-bell" class="w-5 h-5" /> {gettext("Email Subscription Preferences")}
          </h3>
          <div class="animate-pulse space-y-3">
            <div class="h-4 bg-base-300 rounded w-2/3"></div>
            <div class="h-12 bg-base-300 rounded"></div>
            <div class="h-12 bg-base-300 rounded"></div>
            <div class="h-12 bg-base-300 rounded"></div>
          </div>
        </div>
      </div>
    <% else %>
      <%= if !Enum.empty?(@user_emails) do %>
        <div class="card panel-card">
          <div class="card-body p-4 sm:p-6">
            <h3 class="card-title text-base sm:text-lg flex items-center gap-2 mb-4">
              <.icon name="hero-bell" class="w-5 h-5" /> {gettext("Email Subscription Preferences")}
            </h3>

            <p class="text-xs sm:text-sm text-base-content/70 mb-4">
              {gettext(
                "Manage optional email categories when available. Required account and security emails are shown for reference."
              )}
            </p>

            <%= if !@has_subscribable_lists do %>
              <div class="alert alert-info mb-4">
                <.icon name="hero-information-circle" class="w-5 h-5" />
                <span class="text-sm">
                  {gettext(
                    "There are currently no optional platform email categories to unsubscribe from."
                  )}
                </span>
              </div>
            <% end %>

            <div class="space-y-2">
              <%= for list <- @lists do %>
                <div class="bg-base-200 rounded-lg p-3">
                  <div class="flex items-center justify-between gap-3">
                    <div class="flex-1">
                      <div class="flex items-center gap-2 mb-1">
                        <span class="font-medium text-sm">{list.name}</span>
                        <div class={"badge badge-xs #{type_badge_class(list.type)}"}>
                          {format_type(list.type)}
                        </div>
                      </div>
                      <p class="text-xs text-base-content/60">{list.description}</p>
                    </div>
                    <%= if list.can_unsubscribe do %>
                      <% any_subscribed =
                        Enum.any?(@user_emails, fn email ->
                          !get_in(@unsubscribe_status, [email, list.id])
                        end) %>
                      <button
                        phx-click="toggle_subscription"
                        phx-value-list_id={list.id}
                        class={"btn btn-sm #{if any_subscribed, do: "btn-primary", else: "btn-ghost"}"}
                      >
                        <%= if any_subscribed do %>
                          <.icon name="hero-bell" class="w-4 h-4" />
                          <span class="ml-1">{gettext("Subscribed")}</span>
                        <% else %>
                          <.icon name="hero-bell-slash" class="w-4 h-4" />
                          <span class="ml-1">{gettext("Unsubscribed")}</span>
                        <% end %>
                      </button>
                    <% else %>
                      <span class="badge badge-ghost">{gettext("Required")}</span>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% else %>
        <div class="card panel-card">
          <div class="card-body p-4 sm:p-6">
            <div class="alert alert-warning">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span class="text-sm">
                {gettext("No email addresses found for your account.")}
              </span>
            </div>
          </div>
        </div>
      <% end %>
    <% end %>
    """
  end

  def format_fingerprint(nil), do: ""

  def format_fingerprint(fingerprint) do
    fingerprint
    |> String.upcase()
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end

  def wkd_hash(username) do
    PGP.wkd_hash(String.downcase(username))
  end

  defp type_badge_class(:transactional), do: "badge-error"
  defp type_badge_class(:marketing), do: "badge-primary"
  defp type_badge_class(:notifications), do: "badge-info"

  defp format_type(:transactional), do: "Transactional"
  defp format_type(:marketing), do: "Marketing"
  defp format_type(:notifications), do: "Notifications"

  defp assign_private_mailbox_state(socket, mailbox) when not is_nil(mailbox) do
    socket
    |> assign(:private_mailbox_configured, Mailbox.private_storage_configured?(mailbox))
    |> assign(:private_mailbox_enabled, mailbox.private_storage_enabled)
    |> assign(:private_mailbox_public_key, mailbox.private_storage_public_key)
    |> assign(:private_mailbox_wrapped_private_key, mailbox.private_storage_wrapped_private_key)
    |> assign(:private_mailbox_verifier, mailbox.private_storage_verifier)
    |> assign(:private_mailbox_unlock_mode, Mailbox.private_storage_unlock_mode(mailbox))
  end

  defp assign_private_mailbox_state(socket, _mailbox) do
    socket
    |> assign(:private_mailbox_configured, false)
    |> assign(:private_mailbox_enabled, false)
    |> assign(:private_mailbox_public_key, nil)
    |> assign(:private_mailbox_wrapped_private_key, nil)
    |> assign(:private_mailbox_verifier, nil)
    |> assign(:private_mailbox_unlock_mode, "account_password")
  end

  defp decode_private_mailbox_setup_params(params) when is_map(params) do
    with {:ok, decoded} <- decode_payload_field(params, "wrapped_private_key", required: true),
         {:ok, decoded} <- decode_payload_field(decoded, "verifier", required: true),
         public_key when is_binary(public_key) <- Map.get(decoded, "public_key"),
         true <- Elektrine.Strings.present?(public_key),
         unlock_mode <- Map.get(decoded, "unlock_mode", "account_password"),
         true <- unlock_mode in ["account_password", "separate_passphrase"] do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp decode_private_mailbox_setup_params(_params), do: {:error, :invalid_payload}

  defp verify_private_mailbox_setup_password_mode(
         current_user,
         %{"unlock_mode" => "account_password"} = decoded_params
       ) do
    case Map.get(decoded_params, "current_account_password") do
      password when is_binary(password) and password != "" ->
        case Accounts.verify_user_password(current_user, password) do
          {:ok, _user} -> :ok
          _ -> {:error, :invalid_account_password}
        end

      _ ->
        {:error, :invalid_account_password}
    end
  end

  defp verify_private_mailbox_setup_password_mode(_current_user, _decoded_params), do: :ok

  defp private_mailbox_changeset_error(changeset) do
    details =
      changeset.errors
      |> Keyword.keys()
      |> Enum.map_join(", ", &to_string/1)

    if details == "" do
      "Could not enable private mailbox storage."
    else
      "Could not enable private mailbox storage (#{details})."
    end
  end

  defp decode_payload_field(params, field, opts) do
    required? = Keyword.get(opts, :required, false)

    case Map.get(params, field) do
      nil ->
        if required?, do: {:error, :invalid_payload}, else: {:ok, params}

      "" ->
        if required?, do: {:error, :invalid_payload}, else: {:ok, Map.put(params, field, nil)}

      value when is_map(value) ->
        {:ok, params}

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) -> {:ok, Map.put(params, field, decoded)}
          _ -> {:error, :invalid_payload}
        end

      _ ->
        {:error, :invalid_payload}
    end
  end

  defp encode_payload(nil), do: ""
  defp encode_payload(payload) when is_map(payload), do: Jason.encode!(payload)
end
