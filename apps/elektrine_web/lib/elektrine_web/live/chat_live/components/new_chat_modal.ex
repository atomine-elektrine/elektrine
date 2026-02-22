defmodule ElektrineWeb.ChatLive.Components.NewChatModal do
  @moduledoc false
  use ElektrineWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="space-y-3">
      <!-- Chat Type Buttons -->
      <div class="grid grid-cols-2 gap-2 mb-2">
        <button
          phx-click="search_users"
          phx-value-query=""
          phx-target={@myself}
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-user" class="w-4 h-4" /> Direct
        </button>
        <button
          phx-click="show_create_group"
          phx-target={@myself}
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-users" class="w-4 h-4" /> Group
        </button>
      </div>
      <div class="grid grid-cols-2 gap-2">
        <button
          phx-click="show_create_channel"
          phx-target={@myself}
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-megaphone" class="w-4 h-4" /> Channel
        </button>
        <button
          phx-click="show_browse_channels"
          phx-target={@myself}
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-globe-alt" class="w-4 h-4" /> Browse
        </button>
      </div>
      
    <!-- Direct Message Search -->
      <%= if not @show_create_group and not @show_create_channel and not @show_browse_channels do %>
        <input
          type="text"
          placeholder="Search users..."
          value={@search_query}
          phx-keyup="search_users"
          phx-debounce="300"
          phx-target={@myself}
          class="input input-bordered w-full input-sm"
          phx-value-query={@search_query}
        />
        
    <!-- Search Results -->
        <%= if @search_results != [] do %>
          <div class="bg-base-200 rounded-lg border max-h-48 overflow-y-auto">
            <%= for user <- @search_results do %>
              <div
                class="flex items-center gap-3 p-3 hover:bg-base-200 cursor-pointer"
                phx-click="start_dm"
                phx-value-user_id={user.id}
                phx-target={@myself}
              >
                <div class="avatar">
                  <div class="w-8 h-8 rounded-full">
                    <%= if user.avatar do %>
                      <img src={user.avatar} alt={user.handle || user.username} />
                    <% else %>
                      <div class="bg-primary text-primary-content flex items-center justify-center text-sm">
                        {String.upcase(String.first(user.handle || user.username))}
                      </div>
                    <% end %>
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
      <% end %>
      
    <!-- Create Group Form -->
      <%= if @show_create_group do %>
        <.live_component
          module={ElektrineWeb.ChatLive.Components.GroupForm}
          id="group-form"
          search_results={@search_results}
          selected_users={@selected_users}
          search_query={@search_query}
        />
      <% end %>
      
    <!-- Create Channel Form -->
      <%= if @show_create_channel do %>
        <.live_component
          module={ElektrineWeb.ChatLive.Components.ChannelForm}
          id="channel-form"
        />
      <% end %>
      
    <!-- Browse Channels -->
      <%= if @show_browse_channels do %>
        <.live_component
          module={ElektrineWeb.ChatLive.Components.ChannelBrowser}
          id="channel-browser"
          public_channels={@public_channels}
        />
      <% end %>
    </div>
    """
  end

  def handle_event("search_users", %{"query" => query}, socket) do
    send(self(), {:search_users, query})
    {:noreply, socket}
  end

  def handle_event("search_users", %{"value" => query}, socket) do
    send(self(), {:search_users, query})
    {:noreply, socket}
  end

  def handle_event("search_users", _params, socket) do
    send(self(), {:show_direct_search})
    {:noreply, socket}
  end

  def handle_event("start_dm", %{"user_id" => user_id}, socket) do
    send(self(), {:start_dm, user_id})
    {:noreply, socket}
  end

  def handle_event("show_create_group", _params, socket) do
    send(self(), {:show_create_group})
    {:noreply, socket}
  end

  def handle_event("show_create_channel", _params, socket) do
    send(self(), {:show_create_channel})
    {:noreply, socket}
  end

  def handle_event("show_browse_channels", _params, socket) do
    send(self(), {:show_browse_channels})
    {:noreply, socket}
  end
end
