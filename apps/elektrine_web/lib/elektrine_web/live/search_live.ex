defmodule ElektrineWeb.SearchLive do
  use ElektrineWeb, :live_view
  alias Elektrine.Search
  alias Elektrine.Search.RateLimiter, as: SearchRateLimiter
  import ElektrineWeb.Components.Platform.ZNav

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
     |> assign(:active_filter, "all")
     |> assign(:command_mode, false)}
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

    case allow_search_request(socket, :submit) do
      :ok ->
        if String.length(query) < 2 do
          command_mode = String.starts_with?(query, ">")

          if command_mode do
            socket = perform_search(socket, query)
            {:noreply, push_patch(socket, to: ~p"/search?q=#{query}")}
          else
            {:noreply,
             socket
             |> assign(:query, query)
             |> assign(:results, [])
             |> assign(:filtered_results, [])
             |> assign(:total_count, 0)
             |> assign(:show_suggestions, false)
             |> assign(:command_mode, false)}
          end
        else
          socket = perform_search(socket, query)
          {:noreply, push_patch(socket, to: ~p"/search?q=#{query}")}
        end

      {:error, retry_after} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Too many search requests. Please slow down and try again in #{retry_after} seconds."
         )}
    end
  end

  def handle_event("suggest", %{"value" => query}, socket) do
    query = String.trim(query)

    case allow_search_request(socket, :suggest) do
      :ok ->
        socket =
          if String.length(query) >= 2 do
            # Perform live search as user types
            socket = perform_search(socket, query)

            # Also get suggestions
            suggestions = Search.get_suggestions(socket.assigns.current_user, query, 8)

            socket
            |> assign(:suggestions, suggestions)
            |> assign(:show_suggestions, suggestions != [])
            |> assign(:command_mode, String.starts_with?(query, ">"))
          else
            if String.starts_with?(query, ">") do
              socket = perform_search(socket, query)
              suggestions = Search.get_suggestions(socket.assigns.current_user, query, 8)

              socket
              |> assign(:suggestions, suggestions)
              |> assign(:show_suggestions, suggestions != [])
              |> assign(:command_mode, true)
            else
              # Clear results for short queries
              socket
              |> assign(:query, query)
              |> assign(:results, [])
              |> assign(:filtered_results, [])
              |> assign(:total_count, 0)
              |> assign(:suggestions, [])
              |> assign(:show_suggestions, false)
              |> assign(:command_mode, false)
            end
          end

        {:noreply, socket}

      {:error, _retry_after} ->
        {:noreply,
         socket
         |> assign(:query, query)
         |> assign(:show_suggestions, false)
         |> assign(:suggestions, [])}
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
    |> assign(:command_mode, String.starts_with?(query, ">"))
    |> assign(:active_filter, "all")
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

  defp allow_search_request(socket, event_type) do
    user_id = socket.assigns.current_user.id
    rate_limit_key = "search:#{event_type}:#{user_id}"

    try do
      SearchRateLimiter.allow_query(rate_limit_key)
    rescue
      ArgumentError -> :ok
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 pb-2">
      <.z_nav active_tab="search" />

      <div class="mx-auto max-w-4xl space-y-4">
        <div class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body gap-4">
            <div class="flex items-start justify-between gap-3">
              <div>
                <h1 class="text-2xl font-bold">Command Palette</h1>
                <p class="text-sm opacity-70">
                  Search people, messages, emails, communities, files, settings, and actions.
                </p>
              </div>
              <span class="badge badge-ghost">Type `>` for actions</span>
            </div>

            <div class="relative" phx-click-away="clear_suggestions">
              <form phx-submit="search" class="w-full">
                <div class="join w-full">
                  <label class="input input-bordered join-item flex-1 flex items-center gap-2">
                    <.icon name="hero-magnifying-glass" class="h-4 w-4 opacity-60" />
                    <input
                      type="text"
                      name="query"
                      value={@query}
                      placeholder="Search... or use > for commands"
                      class="grow"
                      phx-keyup="suggest"
                      phx-debounce="350"
                      autocomplete="off"
                    />
                  </label>
                  <button type="submit" class="btn btn-neutral join-item">Go</button>
                </div>
              </form>

              <%= if @show_suggestions and @suggestions != [] do %>
                <div class="mt-2 rounded-lg border border-base-300 bg-base-100 shadow-md overflow-hidden max-h-80 overflow-y-auto">
                  <%= for suggestion <- @suggestions do %>
                    <button
                      type="button"
                      class="w-full text-left px-4 py-2.5 hover:bg-base-200 transition-colors border-b border-base-200 last:border-b-0"
                      phx-click="search"
                      phx-value-query={suggestion.text}
                    >
                      <div class="flex items-center justify-between gap-3">
                        <span class="text-sm truncate">{suggestion.text}</span>
                        <span class="badge badge-ghost badge-sm shrink-0">
                          {format_suggestion_type(suggestion.type)}
                        </span>
                      </div>
                    </button>
                  <% end %>
                </div>
              <% end %>
            </div>

            <div class="flex flex-wrap gap-2">
              <button class="btn btn-xs btn-ghost" phx-click="search" phx-value-query=">compose email">
                Compose Email
              </button>
              <button class="btn btn-xs btn-ghost" phx-click="search" phx-value-query=">open chat">
                Open Chat
              </button>
              <button
                class="btn btn-xs btn-ghost"
                phx-click="search"
                phx-value-query=">open notifications"
              >
                Notifications
              </button>
              <button class="btn btn-xs btn-ghost" phx-click="search" phx-value-query="settings">
                Settings
              </button>
            </div>
          </div>
        </div>

        <%= if @loading do %>
          <div class="flex justify-center py-8">
            <.spinner size="md" class="text-primary" />
          </div>
        <% end %>

        <%= if not @loading and @query != "" do %>
          <div class="flex items-center justify-between text-sm opacity-80">
            <p>
              <span class="font-semibold">{@total_count}</span>
              result(s) for <span class="font-semibold">{@query}</span>
            </p>
            <%= if @command_mode do %>
              <span class="badge badge-neutral badge-sm">Command mode</span>
            <% end %>
          </div>

          <%= if @results != [] do %>
            <div class="rounded-lg border border-base-300 bg-base-100 p-2">
              <div class="flex flex-wrap gap-2">
                <button
                  phx-click="filter_results"
                  phx-value-type="all"
                  class={[
                    "btn btn-xs",
                    if(@active_filter == "all", do: "btn-neutral", else: "btn-ghost")
                  ]}
                >
                  All ({length(@results)})
                </button>
                <%= for type <- get_available_types(@results) do %>
                  <button
                    phx-click="filter_results"
                    phx-value-type={type}
                    class={[
                      "btn btn-xs",
                      if(@active_filter == type, do: "btn-neutral", else: "btn-ghost")
                    ]}
                  >
                    {format_result_type(type)} ({count_by_type(@results, type)})
                  </button>
                <% end %>
              </div>
            </div>

            <div class="rounded-lg border border-base-300 bg-base-100 divide-y divide-base-200">
              <%= for result <- @filtered_results do %>
                <.link
                  navigate={result.url}
                  class="flex items-start justify-between gap-4 px-4 py-3 hover:bg-base-200/70 transition-colors"
                >
                  <div class="min-w-0">
                    <div class="flex items-center gap-2 mb-1">
                      <span class={"badge badge-sm " <> type_badge_class(result.type)}>
                        {format_result_type(result.type)}
                      </span>
                      <%= if result.type == "federated" && result[:actor_domain] do %>
                        <span class="badge badge-ghost badge-sm">{result.actor_domain}</span>
                      <% end %>
                    </div>
                    <p class="font-medium truncate">{result.title}</p>
                    <%= if result.content do %>
                      <p class="text-sm opacity-70 truncate">{result.content}</p>
                    <% end %>
                  </div>
                  <div class="text-xs opacity-60 whitespace-nowrap">
                    {format_relative_time(result.updated_at)}
                  </div>
                </.link>
              <% end %>
            </div>
          <% else %>
            <div class="rounded-lg border border-base-300 bg-base-100 p-10 text-center">
              <.icon name="hero-magnifying-glass" class="h-10 w-10 mx-auto opacity-30 mb-3" />
              <p class="font-medium">No matches found</p>
              <p class="text-sm opacity-70">Try a broader query or use `>` for commands.</p>
            </div>
          <% end %>
        <% end %>

        <%= if @query == "" and not @loading do %>
          <div class="rounded-lg border border-base-300 bg-base-100 p-8 text-center">
            <.icon name="hero-command-line" class="h-10 w-10 mx-auto opacity-40 mb-3" />
            <h2 class="text-lg font-semibold mb-2">Global Search</h2>
            <p class="text-sm opacity-70 mb-5">
              Search everything or start a command with `>`.
            </p>
            <div class="flex flex-wrap justify-center gap-2">
              <button class="btn btn-sm btn-ghost" phx-click="search" phx-value-query="@">
                People
              </button>
              <button class="btn btn-sm btn-ghost" phx-click="search" phx-value-query="email">
                Emails
              </button>
              <button class="btn btn-sm btn-ghost" phx-click="search" phx-value-query="community">
                Communities
              </button>
              <button class="btn btn-sm btn-ghost" phx-click="search" phx-value-query=">compose email">
                Actions
              </button>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions for formatting
  defp format_result_type("action"), do: "Action"
  defp format_result_type("settings"), do: "Settings"
  defp format_result_type("person"), do: "People"
  defp format_result_type("chat"), do: "Chat"
  defp format_result_type("timeline"), do: "Timeline"
  defp format_result_type("discussion"), do: "Discussion"
  defp format_result_type("community"), do: "Community"
  defp format_result_type("federated"), do: "Federated"
  defp format_result_type("email"), do: "Email"
  defp format_result_type("file"), do: "File"
  defp format_result_type("mailbox"), do: "Mailbox"
  defp format_result_type(_), do: "Other"

  defp format_suggestion_type("action"), do: "action"
  defp format_suggestion_type("settings"), do: "settings"
  defp format_suggestion_type("person"), do: "person"
  defp format_suggestion_type("email_domain"), do: "domain"
  defp format_suggestion_type(_), do: "other"

  defp type_badge_class("action"), do: "badge-neutral"
  defp type_badge_class("settings"), do: "badge-secondary"
  defp type_badge_class("person"), do: "badge-info"
  defp type_badge_class("chat"), do: "badge-info"
  defp type_badge_class("timeline"), do: "badge-success"
  defp type_badge_class("discussion"), do: "badge-secondary"
  defp type_badge_class("community"), do: "badge-accent"
  defp type_badge_class("federated"), do: "badge-warning"
  defp type_badge_class("email"), do: "badge-primary"
  defp type_badge_class("file"), do: "badge-warning"
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
