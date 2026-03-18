defmodule ElektrineWeb.ChatLive.Components.ChannelModal do
  @moduledoc false
  use ElektrineChatWeb, :live_component

  attr :uploads, :map, default: %{}

  def render(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div
        class="modal-box card p-6 max-w-md w-full mx-4 max-h-[80vh] overflow-y-auto"
        phx-click-away="close_modal"
        phx-target={@myself}
      >
        <div class="flex justify-between items-center mb-6">
          <h2 class="text-xl font-bold">Create Server Channel</h2>
          <button phx-click="close_modal" phx-target={@myself} class="btn btn-ghost btn-sm btn-circle">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <form phx-submit="create_channel" phx-target={@myself} class="space-y-4">
          <div>
            <label class="label">
              <span class="label-text font-semibold">Channel Name</span>
            </label>
            <input
              type="text"
              name="channel[name]"
              placeholder="Server channel name"
              class="input input-bordered w-full"
              required
              autofocus
            />
          </div>

          <div>
            <label class="label">
              <span class="label-text font-semibold">Description</span>
            </label>
            <textarea
              name="channel[description]"
              placeholder="Channel description (optional)"
              class="textarea textarea-bordered w-full"
              rows="2"
            ></textarea>
          </div>

          <%= if @uploads[:channel_avatar_upload] do %>
            <div>
              <label class="label">
                <span class="label-text font-semibold">Channel Image</span>
              </label>
              <div class="flex items-center gap-3">
                <%= if @uploads.channel_avatar_upload.entries != [] do %>
                  <% entry = List.first(@uploads.channel_avatar_upload.entries) %>
                  <div class="w-14 h-14 rounded-lg overflow-hidden bg-base-200 border border-base-300">
                    <.live_img_preview entry={entry} class="w-full h-full object-cover" />
                  </div>
                <% else %>
                  <div class="w-14 h-14 rounded-lg bg-base-200 border border-dashed border-base-300 flex items-center justify-center">
                    <.icon name="hero-photo" class="w-6 h-6 text-base-content/60" />
                  </div>
                <% end %>
                <label class="btn btn-ghost btn-sm">
                  Choose Image
                  <.live_file_input
                    upload={@uploads.channel_avatar_upload}
                    class="hidden"
                    phx-change="validate_upload"
                    phx-target={@myself}
                  />
                </label>
              </div>
              <%= for entry <- @uploads.channel_avatar_upload.entries do %>
                <div class="mt-2 flex items-center gap-2 text-xs">
                  <span class="truncate flex-1">{entry.client_name}</span>
                  <progress
                    class="progress progress-secondary w-28 h-2"
                    value={entry.progress}
                    max="100"
                  >
                  </progress>
                  <button
                    type="button"
                    phx-click="cancel_upload"
                    phx-target="#chat-container"
                    phx-value-ref={entry.ref}
                    phx-value-upload_name="channel_avatar_upload"
                    class="btn btn-ghost btn-xs btn-circle"
                    title="Remove image"
                  >
                    <.icon name="hero-x-mark" class="w-3 h-3" />
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>

          <div>
            <label class="label">
              <span class="label-text font-semibold">Topic</span>
            </label>
            <input
              type="text"
              name="channel[channel_topic]"
              placeholder="Routing topic (optional)"
              class="input input-bordered w-full"
            />
          </div>

          <div>
            <label class="label cursor-pointer">
              <span class="label-text font-semibold">Private Channel</span>
              <input type="hidden" name="channel[is_private]" value="false" />
              <input
                type="checkbox"
                name="channel[is_private]"
                value="true"
                class="checkbox checkbox-primary"
              />
            </label>
            <p class="text-xs text-base-content/60 mt-1">
              Private channels are restricted. Public channels are visible to all server members.
            </p>
          </div>

          <div class="flex gap-3 pt-4">
            <button type="submit" class="btn btn-secondary flex-1">
              <.icon name="hero-megaphone" class="w-4 h-4 mr-2" /> Create Channel
            </button>
            <button
              type="button"
              phx-click="close_modal"
              phx-target={@myself}
              class="btn btn-ghost"
            >
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  def handle_event("close_modal", _params, socket) do
    send(self(), {:close_channel_modal})
    {:noreply, socket}
  end

  def handle_event("create_channel", %{"channel" => channel_params}, socket) do
    send(self(), {:create_channel, channel_params})
    {:noreply, socket}
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end
end
