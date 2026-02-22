defmodule ElektrineWeb.ChatLive.Components.MessageComposer do
  @moduledoc false
  use ElektrineWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="p-4 bg-base-200 border-t border-base-300">
      <!-- Reply Context -->
      <%= if @reply_to do %>
        <div class="mb-3 p-2 bg-base-300 rounded-lg flex items-center justify-between">
          <div class="text-sm">
            <span class="opacity-75">Replying to</span>
            <strong>{@reply_to.sender.username}</strong>:
            <span class="opacity-75 truncate">
              {Elektrine.Messaging.Message.display_content(@reply_to)}
            </span>
          </div>
          <button
            phx-click="cancel_reply"
            phx-target={@myself}
            class="btn btn-xs btn-ghost"
          >
            <.icon name="hero-x-mark" class="w-3 h-3" />
          </button>
        </div>
      <% end %>

      <form phx-submit="send_message" phx-target={@myself} class="space-y-2">
        <div class="flex gap-2 items-end">
          <textarea
            name="message"
            placeholder="Type a message..."
            class="textarea textarea-bordered flex-1 resize-none overflow-y-auto leading-tight"
            style="min-height: 2.5rem; max-height: 10rem; height: 2.5rem;"
            autocomplete="off"
            phx-hook="AutoExpandTextarea"
            id="message-input"
            rows="1"
          >{@new_message}</textarea>
          <div class="dropdown dropdown-top dropdown-end">
            <div tabindex="0" role="button" class="btn btn-ghost">
              <.icon name="hero-paper-clip" class="w-4 h-4" />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content z-30 menu p-2 shadow-lg bg-base-100 rounded-box w-52"
            >
              <li>
                <label class="cursor-pointer">
                  <.icon name="hero-photo" class="w-4 h-4" /> Upload Image
                  <input
                    type="file"
                    class="hidden"
                    accept="image/*"
                    phx-change="upload_image"
                    phx-target={@myself}
                  />
                </label>
              </li>
              <li>
                <label class="cursor-pointer">
                  <.icon name="hero-document" class="w-4 h-4" /> Upload File
                  <input
                    type="file"
                    class="hidden"
                    phx-change="upload_file"
                    phx-target={@myself}
                  />
                </label>
              </li>
            </ul>
          </div>
          <button
            type="submit"
            class="btn btn-primary"
            disabled={String.trim(@new_message) == ""}
          >
            <.icon name="hero-paper-airplane" class="w-4 h-4" />
          </button>
        </div>
      </form>
    </div>
    """
  end

  def handle_event("send_message", %{"message" => message_content}, socket) do
    send(self(), {:send_message, message_content})
    {:noreply, assign(socket, :new_message, "")}
  end

  def handle_event("cancel_reply", _params, socket) do
    send(self(), {:cancel_reply})
    {:noreply, socket}
  end

  def handle_event("upload_image", _params, socket) do
    # Handle image upload
    {:noreply, socket}
  end

  def handle_event("upload_file", _params, socket) do
    # Handle file upload
    {:noreply, socket}
  end
end
