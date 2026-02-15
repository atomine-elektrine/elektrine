defmodule ElektrineWeb.SearchLive do
  use ElektrineWeb, :live_view
  alias Elektrine.Search

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:filtered_results, [])
     |> assign(:total_count, 0)
     |> assign(:loading, false)
     |> assign(:suggestions, [])
     |> assign(:show_suggestions, false)
     |> assign(:active_filter, "all")}
  end

  @impl true
  def handle_params(%{"q" => query}, _uri, socket) when byte_size(query) > 0 do
    socket = perform_search(socket, query)
    {:noreply, assign(socket, :query, query)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    # Rate limit: uses default (5 per minute, 10 per hour)
    user_id = socket.assigns.current_user.id
    rate_limit_key = "search:#{user_id}"

    case Elektrine.Auth.RateLimiter.check_rate_limit(rate_limit_key) do
      {:ok, :allowed} ->
        Elektrine.Auth.RateLimiter.record_failed_attempt(rate_limit_key)

        if String.length(query) < 2 do
          {:noreply,
           socket
           |> assign(:query, query)
           |> assign(:results, [])
           |> assign(:filtered_results, [])
           |> assign(:total_count, 0)
           |> assign(:show_suggestions, false)}
        else
          socket = perform_search(socket, query)
          {:noreply, push_patch(socket, to: ~p"/search?q=#{query}")}
        end

      {:error, {:rate_limited, _retry_after, _reason}} ->
        {:noreply, put_flash(socket, :error, "Too many search requests. Please slow down.")}
    end
  end

  def handle_event("suggest", %{"value" => query}, socket) do
    query = String.trim(query)

    # Rate limit: uses default (5 per minute, 10 per hour)
    user_id = socket.assigns.current_user.id
    rate_limit_key = "search_suggest:#{user_id}"

    case Elektrine.Auth.RateLimiter.check_rate_limit(rate_limit_key) do
      {:ok, :allowed} ->
        Elektrine.Auth.RateLimiter.record_failed_attempt(rate_limit_key)

        socket =
          if String.length(query) >= 2 do
            # Perform live search as user types
            socket = perform_search(socket, query)

            # Also get suggestions
            suggestions = Search.get_suggestions(socket.assigns.current_user, query, 8)

            socket
            |> assign(:suggestions, suggestions)
            |> assign(:show_suggestions, suggestions != [])
          else
            # Clear results for short queries
            socket
            |> assign(:query, query)
            |> assign(:results, [])
            |> assign(:filtered_results, [])
            |> assign(:total_count, 0)
            |> assign(:suggestions, [])
            |> assign(:show_suggestions, false)
          end

        {:noreply, socket}

      {:error, {:rate_limited, _retry_after, _reason}} ->
        {:noreply, put_flash(socket, :error, "Too many search requests. Please slow down.")}
    end
  end

  def handle_event("clear_suggestions", _params, socket) do
    {:noreply, assign(socket, :show_suggestions, false)}
  end

  def handle_event("filter_results", %{"type" => filter_type}, socket) do
    {:noreply,
     socket
     |> assign(:active_filter, filter_type)
     |> apply_search_filter()}
  end

  defp perform_search(socket, query) do
    user = socket.assigns.current_user

    socket
    |> assign(:loading, true)
    |> assign(:query, query)
    |> then(fn socket ->
      search_results = Search.global_search(user, query, limit: 50)

      socket
      |> assign(:results, search_results.results)
      |> assign(:total_count, search_results.total_count)
      |> assign(:loading, false)
      |> assign(:show_suggestions, false)
      |> apply_search_filter()
    end)
  end

  defp apply_search_filter(socket) do
    filtered =
      case socket.assigns.active_filter do
        "all" ->
          socket.assigns.results

        type ->
          Enum.filter(socket.assigns.results, &(&1.type == type))
      end

    assign(socket, :filtered_results, filtered)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <!-- Search Header -->
      <div class="card glass-card shadow-lg rounded-2xl mb-8">
        <div class="card-body">
          <h1 class="text-2xl sm:text-3xl font-bold text-base-content mb-6">Search</h1>
          
    <!-- Search Input -->
          <div class="relative">
            <form phx-submit="search" class="w-full">
              <div class="flex gap-2 w-full">
                <input
                  type="text"
                  name="query"
                  value={@query}
                  placeholder="Search messages, posts, discussions, federated, emails..."
                  class="input input-bordered flex-1 rounded-xl"
                  phx-keyup="suggest"
                  phx-blur="clear_suggestions"
                  phx-debounce="300"
                  autocomplete="off"
                  phx-value-query={@query}
                />
                <button type="submit" class="btn btn-primary">
                  <.icon name="hero-magnifying-glass" class="h-5 w-5" />
                  <span class="hidden sm:inline ml-1">Search</span>
                </button>
              </div>
            </form>
            
    <!-- Search Suggestions -->
            <%= if @show_suggestions and (@suggestions) != [] do %>
              <div class="absolute top-full left-0 right-0 bg-base-100 border border-base-300 rounded-xl shadow-lg mt-2 z-50 overflow-hidden">
                <%= for suggestion <- @suggestions do %>
                  <div
                    class="px-4 py-3 hover:bg-base-200 cursor-pointer border-b border-base-200 last:border-b-0"
                    phx-click="search"
                    phx-value-query={suggestion.text}
                  >
                    <div class="flex items-center justify-between">
                      <span class="text-sm text-base-content">{suggestion.text}</span>
                      <span class="badge badge-ghost badge-sm">
                        {format_suggestion_type(suggestion.type)}
                      </span>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
      
    <!-- Loading State -->
      <%= if @loading do %>
        <div class="flex justify-center py-8">
          <.spinner size="md" class="text-primary" />
        </div>
      <% end %>
      
    <!-- Search Results -->
      <%= if not @loading and @query != "" do %>
        <div class="mb-4">
          <p class="text-sm text-base-content/70">
            Found <span class="font-semibold text-base-content">{@total_count}</span>
            results for "<span class="font-semibold text-base-content"><%= @query %></span>"
          </p>
        </div>

        <%= if (@results) != [] do %>
          <!-- Filter Tabs -->
          <div class="card glass-card shadow rounded-xl p-2 mb-4">
            <div class="flex flex-wrap gap-2">
              <button
                phx-click="filter_results"
                phx-value-type="all"
                class={[
                  "btn btn-sm",
                  (@active_filter == "all" && "btn-primary") || "btn-ghost"
                ]}
              >
                All ({length(@results)})
              </button>
              <%= for type <- get_available_types(@results) do %>
                <button
                  phx-click="filter_results"
                  phx-value-type={type}
                  class={[
                    "btn btn-sm",
                    (@active_filter == type && "btn-primary") || "btn-ghost"
                  ]}
                >
                  {format_result_type(type)} ({count_by_type(@results, type)})
                </button>
              <% end %>
            </div>
          </div>

          <div class="space-y-3">
            <%= for result <- @filtered_results do %>
              <div class="card glass-card shadow rounded-xl hover:shadow-md transition-all">
                <div class="card-body p-4">
                  <div class="flex items-start justify-between">
                    <div class="flex-1 min-w-0">
                      <div class="flex items-center gap-2 mb-2">
                        <span class={"badge badge-sm " <> type_badge_class(result.type)}>
                          {format_result_type(result.type)}
                        </span>
                        <%= if result.type == "federated" && result[:actor_domain] do %>
                          <span class="badge badge-sm badge-ghost">
                            {result.actor_domain}
                          </span>
                        <% end %>
                      </div>

                      <h3 class="font-semibold text-base mb-1 truncate">
                        <a
                          href={result.url}
                          class="text-base-content hover:text-primary transition-colors"
                        >
                          {result.title}
                        </a>
                      </h3>

                      <%= if result.type == "federated" && result[:actor_username] do %>
                        <p class="text-xs text-secondary mb-1">
                          @{result.actor_username}@{result[:actor_domain]}
                        </p>
                      <% end %>

                      <%= if result.content do %>
                        <p class="text-sm text-base-content/60 line-clamp-2 break-words">
                          {result.content}
                        </p>
                      <% end %>
                    </div>

                    <div class="text-xs text-base-content/50 ml-4 whitespace-nowrap">
                      {format_relative_time(result.updated_at)}
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% else %>
          <div class="card glass-card shadow-lg rounded-2xl">
            <div class="card-body text-center py-12">
              <.icon name="hero-magnifying-glass" class="h-12 w-12 mx-auto text-base-content/30 mb-4" />
              <h3 class="text-lg font-semibold text-base-content/70 mb-2">No results found</h3>
              <p class="text-sm text-base-content/50">
                Try adjusting your search terms or browse by category
              </p>
            </div>
          </div>
        <% end %>
      <% end %>
      
    <!-- Empty State -->
      <%= if @query == "" and not @loading do %>
        <div class="card glass-card shadow-lg rounded-2xl">
          <div class="card-body text-center py-12">
            <.icon name="hero-magnifying-glass" class="h-16 w-16 mx-auto text-base-content/30 mb-4" />
            <h2 class="text-xl font-semibold text-base-content mb-2">Search Everything</h2>
            <p class="text-base-content/60 mb-8">
              Search across Chat, Timeline, Discussions, Federated Posts, and Emails
            </p>
            
    <!-- Quick Search Categories -->
            <div class="max-w-md mx-auto">
              <h3 class="text-sm font-semibold text-base-content/60 mb-3">Quick Searches</h3>
              <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
                <button class="btn btn-sm btn-ghost" phx-click="search" phx-value-query="@">
                  <.icon name="hero-at-symbol" class="h-4 w-4" /> Mentions
                </button>
                <button class="btn btn-sm btn-ghost" phx-click="search" phx-value-query="#">
                  <.icon name="hero-hashtag" class="h-4 w-4" /> Hashtags
                </button>
                <button class="btn btn-sm btn-ghost" phx-click="search" phx-value-query="discussion">
                  <.icon name="hero-chat-bubble-bottom-center-text" class="h-4 w-4" /> Discussions
                </button>
                <button
                  class="btn btn-sm btn-secondary btn-outline"
                  phx-click="search"
                  phx-value-query="mastodon"
                >
                  <.icon name="hero-globe-alt" class="h-4 w-4" /> Fediverse
                </button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper functions for formatting
  defp format_result_type("chat"), do: "Chat"
  defp format_result_type("timeline"), do: "Timeline"
  defp format_result_type("discussion"), do: "Discussion"
  defp format_result_type("community"), do: "Community"
  defp format_result_type("federated"), do: "Federated"
  defp format_result_type("email"), do: "Email"
  defp format_result_type("mailbox"), do: "Mailbox"
  defp format_result_type(_), do: "Other"

  defp format_suggestion_type("email_domain"), do: "domain"
  defp format_suggestion_type(_), do: "other"

  defp type_badge_class("chat"), do: "badge-info"
  defp type_badge_class("timeline"), do: "badge-success"
  defp type_badge_class("discussion"), do: "badge-secondary"
  defp type_badge_class("community"), do: "badge-accent"
  defp type_badge_class("federated"), do: "badge-warning"
  defp type_badge_class("email"), do: "badge-primary"
  defp type_badge_class("mailbox"), do: "badge-primary"
  defp type_badge_class(_), do: "badge-neutral"

  defp get_available_types(results) do
    results
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp count_by_type(results, type) do
    Enum.count(results, &(&1.type == type))
  end

  defp format_relative_time(%DateTime{} = datetime) do
    case DateTime.diff(DateTime.utc_now(), datetime, :day) do
      0 -> "Today"
      1 -> "Yesterday"
      days when days < 7 -> "#{days} days ago"
      days when days < 30 -> "#{div(days, 7)} weeks ago"
      days -> "#{div(days, 30)} months ago"
    end
  end

  defp format_relative_time(%NaiveDateTime{} = naive_datetime) do
    datetime = DateTime.from_naive!(naive_datetime, "Etc/UTC")
    format_relative_time(datetime)
  end

  defp format_relative_time(nil), do: "Unknown"
end
