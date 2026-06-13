defmodule ElektrineEmailWeb.EmailLive.Settings.SenderSettings do
  @moduledoc """
  Blocked sender and safe sender settings: event handlers, tab data loading,
  and per-tab render functions for `ElektrineEmailWeb.EmailLive.Settings`.
  """

  use Phoenix.Component

  import Phoenix.LiveView, only: [put_flash: 3]
  import ElektrineEmailWeb.EmailLive.Settings.Helpers

  alias Elektrine.Email
  alias Elektrine.Email.{BlockedSender, SafeSender}

  # Tab data loading

  def load_tab_data(socket, "blocked") do
    user_id = socket.assigns.current_user.id

    socket
    |> assign(:blocked_senders, Email.list_blocked_senders(user_id))
    |> assign(:new_blocked, %BlockedSender{})
  end

  def load_tab_data(socket, "safe") do
    user_id = socket.assigns.current_user.id

    socket
    |> assign(:safe_senders, Email.list_safe_senders(user_id))
    |> assign(:new_safe, %SafeSender{})
  end

  # Blocked Senders Events

  def handle_event("block_sender", %{"type" => type, "value" => value}, socket) do
    user_id = socket.assigns.current_user.id
    reason = nil

    result =
      case type do
        "email" -> Email.block_email(user_id, value, reason)
        "domain" -> Email.block_domain(user_id, value, reason)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Sender blocked successfully")
         |> assign(:blocked_senders, Email.list_blocked_senders(user_id))}

      {:error, changeset} ->
        error = get_changeset_error(changeset)

        {:noreply, put_flash(socket, :error, "Failed to block sender: #{error}")}
    end
  end

  def handle_event("unblock_sender", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_blocked_sender(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Blocked sender not found")}

      blocked ->
        {:ok, _} = Email.delete_blocked_sender(blocked)

        {:noreply,
         socket
         |> put_flash(:info, "Sender unblocked")
         |> assign(:blocked_senders, Email.list_blocked_senders(user_id))}
    end
  end

  # Safe Senders Events

  def handle_event("add_safe_sender", %{"type" => type, "value" => value}, socket) do
    user_id = socket.assigns.current_user.id

    result =
      case type do
        "email" -> Email.add_safe_email(user_id, value)
        "domain" -> Email.add_safe_domain(user_id, value)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Safe sender added successfully")
         |> assign(:safe_senders, Email.list_safe_senders(user_id))}

      {:error, changeset} ->
        error = get_changeset_error(changeset)

        {:noreply, put_flash(socket, :error, "Failed to add safe sender: #{error}")}
    end
  end

  def handle_event("remove_safe_sender", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Email.get_safe_sender(String.to_integer(id), user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Safe sender not found")}

      safe ->
        {:ok, _} = Email.delete_safe_sender(safe)

        {:noreply,
         socket
         |> put_flash(:info, "Safe sender removed")
         |> assign(:safe_senders, Email.list_safe_senders(user_id))}
    end
  end

  # Render functions

  def render_blocked_tab(assigns) do
    ~H"""
    <div>
      <div class="mb-4">
        <h2 class="text-xl font-semibold">Blocked Senders</h2>
        <p class="mt-1 text-base-content/70">
          Emails from blocked addresses or domains will be automatically rejected.
        </p>
      </div>
      
    <!-- Add Form -->
      <form phx-submit="block_sender" class="flex gap-2 mb-6">
        <div class="select select-bordered">
          <select name="type">
            <option value="email">Email Address</option>
            <option value="domain">Domain</option>
          </select>
        </div>
        <input
          type="text"
          name="value"
          placeholder="email@example.com or example.com"
          class="input input-bordered flex-1"
          required
        />
        <button type="submit" class="btn btn-secondary">Block</button>
      </form>
      
    <!-- List -->
      <div class="space-y-2">
        <%= for blocked <- @blocked_senders do %>
          <div class="flex items-center justify-between p-3 bg-base-100/50 rounded-lg border border-base-content/10">
            <div>
              <%= if blocked.email do %>
                <span class="badge badge-ghost mr-2">Email</span>
                <span>{blocked.email}</span>
              <% else %>
                <span class="badge badge-ghost mr-2">Domain</span>
                <span>{blocked.domain}</span>
              <% end %>
              <%= if blocked.reason do %>
                <span class="text-sm text-base-content/50 ml-2">({blocked.reason})</span>
              <% end %>
            </div>
            <button
              phx-click="unblock_sender"
              phx-value-id={blocked.id}
              class="btn btn-ghost btn-sm text-error"
            >
              Unblock
            </button>
          </div>
        <% end %>
        <%= if Enum.empty?(@blocked_senders) do %>
          <p class="text-base-content/50 text-center py-4">No blocked senders</p>
        <% end %>
      </div>
    </div>
    """
  end

  def render_safe_tab(assigns) do
    ~H"""
    <div>
      <div class="mb-4">
        <h2 class="text-xl font-semibold">Spam Exceptions</h2>
        <p class="mt-1 text-base-content/70">
          Add sender addresses or domains that should bypass automatic spam-folder classification.
          Server-side security checks can still reject dangerous or unauthenticated mail.
        </p>
      </div>
      
    <!-- Add Form -->
      <form phx-submit="add_safe_sender" class="flex gap-2 mb-6">
        <div class="select select-bordered">
          <select name="type">
            <option value="email">Email Address</option>
            <option value="domain">Domain</option>
          </select>
        </div>
        <input
          type="text"
          name="value"
          placeholder="email@example.com or example.com"
          class="input input-bordered flex-1"
          required
        />
        <button type="submit" class="btn btn-secondary">Add</button>
      </form>
      
    <!-- List -->
      <div class="space-y-2">
        <%= for safe <- @safe_senders do %>
          <div class="flex items-center justify-between p-3 bg-base-100/50 rounded-lg border border-base-content/10">
            <div>
              <%= if safe.email do %>
                <span class="badge badge-ghost mr-2">Email</span>
                <span>{safe.email}</span>
              <% else %>
                <span class="badge badge-ghost mr-2">Domain</span>
                <span>{safe.domain}</span>
              <% end %>
            </div>
            <button
              phx-click="remove_safe_sender"
              phx-value-id={safe.id}
              class="btn btn-ghost btn-sm text-error"
            >
              Remove
            </button>
          </div>
        <% end %>
        <%= if Enum.empty?(@safe_senders) do %>
          <p class="text-base-content/50 text-center py-4">No spam exceptions</p>
        <% end %>
      </div>
    </div>
    """
  end
end
