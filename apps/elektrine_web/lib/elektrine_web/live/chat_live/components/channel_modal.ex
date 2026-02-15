defmodule ElektrineWeb.ChatLive.Components.ChannelModal do
  use ElektrineWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div
        class="bg-base-100 rounded-lg shadow-xl border border-base-300 p-6 max-w-md w-full mx-4 max-h-[80vh] overflow-y-auto"
        phx-click-away="close_modal"
        phx-target={@myself}
      >
        <div class="flex justify-between items-center mb-6">
          <h2 class="text-xl font-bold">Create Channel</h2>
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
              placeholder="Channel name"
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

          <div>
            <label class="label cursor-pointer">
              <span class="label-text font-semibold">Make Public</span>
              <input
                type="checkbox"
                name="channel[is_public]"
                value="true"
                class="checkbox checkbox-primary"
              />
            </label>
            <p class="text-xs text-base-content/60 mt-1">
              Public channels can be discovered and joined by anyone
            </p>
          </div>

          <div class="flex gap-3 pt-4">
            <button type="submit" class="btn btn-primary flex-1">
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
end
