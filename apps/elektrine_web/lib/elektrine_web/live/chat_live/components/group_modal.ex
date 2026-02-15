defmodule ElektrineWeb.ChatLive.Components.GroupModal do
  use ElektrineWeb, :live_component
  import ElektrineWeb.Components.User.Avatar

  attr :group_name, :string, default: ""
  attr :group_description, :string, default: ""
  attr :group_is_public, :boolean, default: false
  attr :search_query, :string, default: ""
  attr :search_results, :list, default: []
  attr :selected_users, :list, default: []

  def render(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div
        class="bg-base-100 rounded-lg shadow-xl border border-base-300 p-6 max-w-md w-full mx-4 max-h-[80vh] overflow-y-auto"
        phx-click-away="close_modal"
        phx-target={@myself}
      >
        <div class="flex justify-between items-center mb-6">
          <h2 class="text-xl font-bold">Create Group</h2>
          <button phx-click="close_modal" phx-target={@myself} class="btn btn-ghost btn-sm btn-circle">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <form phx-submit="create_group" phx-target={@myself} class="space-y-4">
          <div>
            <label class="label">
              <span class="label-text font-semibold">Group Name</span>
            </label>
            <input
              type="text"
              name="group[name]"
              value={@group_name}
              placeholder="Group name"
              class="input input-bordered w-full"
              phx-change="update_group_form"
              required
              autofocus
            />
          </div>

          <div>
            <label class="label">
              <span class="label-text font-semibold">Description</span>
            </label>
            <textarea
              name="group[description]"
              placeholder="Group description (optional)"
              class="textarea textarea-bordered w-full"
              phx-change="update_group_form"
              rows="2"
            >{@group_description}</textarea>
          </div>

          <div>
            <label class="label cursor-pointer">
              <span class="label-text font-semibold">Make Public</span>
              <input
                type="checkbox"
                name="group[is_public]"
                class="checkbox checkbox-primary"
                checked={@group_is_public}
                phx-change="update_group_form"
                value="true"
              />
            </label>
            <p class="text-xs text-base-content/60 mt-1">
              Public groups can be discovered and joined by anyone
            </p>
          </div>

          <div>
            <label class="label">
              <span class="label-text font-semibold">Add Members</span>
            </label>
            <input
              type="text"
              placeholder="Search users to add..."
              value={@search_query}
              phx-keyup="search_users"
              phx-debounce="300"
              phx-target={@myself}
              class="input input-bordered w-full"
              name="query"
            />
          </div>
          
    <!-- Selected Users -->
          <%= if @selected_users != [] do %>
            <div class="flex flex-wrap gap-2">
              <%= for user <- @selected_users do %>
                <div class="badge badge-primary gap-2">
                  {user.handle || user.username}
                  <button
                    type="button"
                    phx-click="toggle_user_selection"
                    phx-value-user_id={user.id}
                    phx-target={@myself}
                    class="hover:text-primary-content"
                  >
                    <.icon name="hero-x-mark" class="w-3 h-3" />
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>
          
    <!-- User Search Results -->
          <%= if @search_results != [] do %>
            <div class="bg-base-200 rounded border max-h-40 overflow-y-auto">
              <%= for user <- @search_results do %>
                <div
                  class={[
                    "flex items-center gap-3 p-3 hover:bg-base-300 cursor-pointer",
                    Enum.any?(@selected_users, &(&1.id == user.id)) && "bg-primary/20"
                  ]}
                  phx-click="toggle_user_selection"
                  phx-value-user_id={user.id}
                  phx-target={@myself}
                >
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm"
                    checked={Enum.any?(@selected_users, &(&1.id == user.id))}
                    readonly
                  />
                  <div class="avatar">
                    <div class="w-8 h-8 rounded-full">
                      <.user_avatar user={user} size="sm" />
                    </div>
                  </div>
                  <div>
                    <p class="font-medium text-sm">
                      {user.display_name || user.handle || user.username}
                    </p>
                    <p class="text-xs opacity-70">@{user.handle || user.username}</p>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>

          <div class="flex gap-3 pt-4">
            <button
              type="submit"
              class="btn btn-primary flex-1"
              disabled={length(@selected_users) == 0}
            >
              <.icon name="hero-users" class="w-4 h-4 mr-2" />
              Create Group ({length(@selected_users)} members)
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
    send(self(), {:close_group_modal})
    {:noreply, socket}
  end

  def handle_event("create_group", %{"group" => group_params}, socket) do
    send(self(), {:create_group, group_params, socket.assigns.selected_users})
    {:noreply, socket}
  end

  def handle_event("search_users", %{"query" => query}, socket) do
    send(self(), {:search_users_for_group, query})
    {:noreply, assign(socket, :search_query, query)}
  end

  def handle_event("search_users", %{"value" => query}, socket) do
    send(self(), {:search_users_for_group, query})
    {:noreply, assign(socket, :search_query, query)}
  end

  def handle_event("update_group_form", %{"group" => group_params}, socket) do
    send(self(), {:update_group_form, group_params})
    {:noreply, socket}
  end

  def handle_event("update_group_form", %{"_target" => ["group", "is_public"]} = params, socket) do
    # Handle checkbox toggle - when unchecked, the value won't be in params
    group_params = Map.get(params, "group", %{})
    group_params = Map.put(group_params, "is_public", Map.has_key?(group_params, "is_public"))

    send(self(), {:update_group_form, group_params})
    {:noreply, socket}
  end

  def handle_event("update_group_form", params, socket) do
    # Fallback for other form updates
    group_params = Map.get(params, "group", %{})
    send(self(), {:update_group_form, group_params})
    {:noreply, socket}
  end

  def handle_event("toggle_user_selection", %{"user_id" => user_id}, socket) do
    send(self(), {:toggle_user_selection, user_id})
    {:noreply, socket}
  end
end
