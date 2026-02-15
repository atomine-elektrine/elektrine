defmodule ElektrineWeb.SettingsLive.RSS do
  use ElektrineWeb, :live_view

  alias Elektrine.RSS

  on_mount {ElektrineWeb.Live.AuthHooks, :require_authenticated_user}
  on_mount {ElektrineWeb.Live.Hooks.NotificationCountHook, :default}
  on_mount {ElektrineWeb.Live.Hooks.PresenceHook, :default}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    subscriptions = RSS.list_subscriptions(user.id)

    {:ok,
     socket
     |> assign(:page_title, "RSS Feeds")
     |> assign(:subscriptions, subscriptions)
     |> assign(:new_feed_url, "")
     |> assign(:adding_feed, false)
     |> assign(:error_message, nil)}
  end

  @impl true
  def handle_event("add_feed", %{"url" => url}, socket) do
    url = String.trim(url)

    if url == "" do
      {:noreply, assign(socket, :error_message, "Please enter a feed URL")}
    else
      socket = assign(socket, :adding_feed, true)

      case RSS.subscribe(socket.assigns.current_user.id, url) do
        {:ok, subscription} ->
          # Trigger immediate fetch of the new feed
          %{feed_id: subscription.feed_id}
          |> Elektrine.RSS.FetchFeedWorker.new()
          |> Oban.insert()

          {:noreply,
           socket
           |> assign(:subscriptions, [subscription | socket.assigns.subscriptions])
           |> assign(:new_feed_url, "")
           |> assign(:adding_feed, false)
           |> assign(:error_message, nil)
           |> put_flash(:info, "Feed added! It will be fetched shortly.")}

        {:error, changeset} ->
          error =
            case changeset.errors[:feed_id] do
              {_, [constraint: :unique, constraint_name: _]} ->
                "You're already subscribed to this feed"

              _ ->
                "Failed to add feed. Please check the URL."
            end

          {:noreply,
           socket
           |> assign(:adding_feed, false)
           |> assign(:error_message, error)}
      end
    end
  end

  @impl true
  def handle_event("update_url", %{"value" => value}, socket) do
    {:noreply, assign(socket, :new_feed_url, value)}
  end

  @impl true
  def handle_event("remove_feed", %{"feed_id" => feed_id}, socket) do
    feed_id = String.to_integer(feed_id)

    case RSS.unsubscribe(socket.assigns.current_user.id, feed_id) do
      {:ok, _} ->
        subscriptions =
          Enum.reject(socket.assigns.subscriptions, &(&1.feed_id == feed_id))

        {:noreply,
         socket
         |> assign(:subscriptions, subscriptions)
         |> put_flash(:info, "Unsubscribed from feed")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unsubscribe")}
    end
  end

  @impl true
  def handle_event("toggle_timeline", %{"subscription_id" => subscription_id}, socket) do
    subscription_id = String.to_integer(subscription_id)

    subscription =
      Enum.find(socket.assigns.subscriptions, &(&1.id == subscription_id))

    if subscription do
      new_value = !subscription.show_in_timeline

      case RSS.update_subscription(subscription, %{show_in_timeline: new_value}) do
        {:ok, updated} ->
          subscriptions =
            Enum.map(socket.assigns.subscriptions, fn s ->
              if s.id == subscription_id, do: updated, else: s
            end)

          {:noreply, assign(socket, :subscriptions, subscriptions)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update subscription")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-4">
      <div class="card glass-card shadow-lg">
        <div class="card-body">
          <h2 class="card-title text-2xl mb-4">
            <.icon name="hero-rss" class="w-6 h-6 text-warning" /> RSS Feeds
          </h2>

          <p class="text-base-content/70 mb-6">
            Subscribe to RSS feeds to see articles in your timeline.
          </p>
          
    <!-- Add Feed Form -->
          <form phx-submit="add_feed" class="mb-8">
            <div class="form-control">
              <label class="label">
                <span class="label-text font-medium">Add a new feed</span>
              </label>
              <div class="flex gap-2">
                <input
                  type="url"
                  name="url"
                  value={@new_feed_url}
                  phx-change="update_url"
                  placeholder="https://example.com/feed.xml"
                  class={[
                    "input input-bordered flex-1",
                    @error_message && "input-error"
                  ]}
                  disabled={@adding_feed}
                />
                <button
                  type="submit"
                  class="btn btn-secondary"
                  disabled={@adding_feed}
                >
                  <%= if @adding_feed do %>
                    <.spinner size="sm" /> Adding...
                  <% else %>
                    Add Feed
                  <% end %>
                </button>
              </div>
              <%= if @error_message do %>
                <label class="label">
                  <span class="label-text-alt text-error">{@error_message}</span>
                </label>
              <% end %>
            </div>
          </form>
          
    <!-- Subscriptions List -->
          <div class="space-y-4">
            <h3 class="font-semibold text-lg">Your Subscriptions</h3>

            <%= if Enum.empty?(@subscriptions) do %>
              <div class="text-center py-8 text-base-content/60">
                <.icon name="hero-rss" class="w-12 h-12 mx-auto mb-4 opacity-40" />
                <p>No feeds subscribed yet</p>
                <p class="text-sm mt-1">Add a feed URL above to get started</p>
              </div>
            <% else %>
              <div class="space-y-2">
                <%= for subscription <- @subscriptions do %>
                  <div class="flex items-center gap-4 p-4 bg-base-200/50 rounded-lg">
                    <div class="flex-shrink-0">
                      <%= if subscription.feed && subscription.feed.favicon_url do %>
                        <img
                          src={subscription.feed.favicon_url}
                          alt=""
                          class="w-8 h-8 rounded"
                          onerror="this.style.display='none'"
                        />
                      <% else %>
                        <div class="w-8 h-8 rounded bg-base-300 flex items-center justify-center">
                          <.icon name="hero-rss" class="w-4 h-4 text-warning" />
                        </div>
                      <% end %>
                    </div>

                    <div class="flex-1 min-w-0">
                      <div class="font-medium truncate">
                        {subscription.display_name ||
                          (subscription.feed && subscription.feed.title) ||
                          "Untitled Feed"}
                      </div>
                      <div class="text-sm text-base-content/60 truncate">
                        {subscription.feed && subscription.feed.url}
                      </div>
                      <%= if subscription.feed && subscription.feed.last_error do %>
                        <div class="text-xs text-error mt-1">
                          Error: {subscription.feed.last_error}
                        </div>
                      <% end %>
                    </div>

                    <div class="flex items-center gap-2">
                      <!-- Show in Timeline Toggle -->
                      <label class="label cursor-pointer gap-2">
                        <span class="label-text text-xs">Timeline</span>
                        <input
                          type="checkbox"
                          class="toggle toggle-sm toggle-secondary"
                          checked={subscription.show_in_timeline}
                          phx-click="toggle_timeline"
                          phx-value-subscription_id={subscription.id}
                        />
                      </label>
                      
    <!-- Remove Button -->
                      <button
                        phx-click="remove_feed"
                        phx-value-feed_id={subscription.feed_id}
                        class="btn btn-ghost btn-sm text-error"
                        title="Unsubscribe"
                      >
                        <.icon name="hero-trash" class="w-4 h-4" />
                      </button>
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
end
