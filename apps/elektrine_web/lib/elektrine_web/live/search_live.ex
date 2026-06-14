defmodule ElektrineWeb.SearchLive do
  use ElektrineWeb, :live_view
  alias Elektrine.Search
  alias Elektrine.Search.RateLimiter, as: SearchRateLimiter
  import ElektrineWeb.Components.Platform.ENav

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:total_count, 0)
     |> assign(:searched?, false)
     |> assign(:loading, false)
     |> assign(:suggestions, [])
     |> assign(:show_suggestions, false)
     |> assign(:active_lens, "all")
     |> assign(:command_mode, false)
     |> assign_web_search_access()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = String.trim(params["q"] || "")
    lens = normalize_lens(params["lens"])

    socket =
      socket
      |> assign_web_search_access()
      |> assign(:active_lens, lens)

    if query != "" do
      {:noreply, perform_search(socket, query, lens: lens)}
    else
      {:noreply, socket |> assign(:query, query) |> assign(:searched?, false)}
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    case allow_search_request(socket, :submit) do
      :ok ->
        if String.starts_with?(query, ">") do
          handle_command_submit(socket, query)
        else
          if String.length(query) < 2 do
            {:noreply,
             socket
             |> assign(:query, query)
             |> assign(:results, [])
             |> assign(:total_count, 0)
             |> assign(:searched?, false)
             |> assign(:show_suggestions, false)
             |> assign(:command_mode, false)}
          else
            {:noreply, push_patch(socket, to: search_path(query, socket.assigns.active_lens))}
          end
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
            suggestions = get_suggestions(socket, query)

            socket
            |> assign_pending_query(query)
            |> assign(:suggestions, suggestions)
            |> assign(:show_suggestions, suggestions != [])
            |> assign(:command_mode, String.starts_with?(query, ">"))
          else
            if String.starts_with?(query, ">") do
              suggestions = get_suggestions(socket, query)

              socket
              |> assign_pending_query(query)
              |> assign(:suggestions, suggestions)
              |> assign(:show_suggestions, suggestions != [])
              |> assign(:command_mode, true)
            else
              # Clear results for short queries
              socket
              |> assign(:query, query)
              |> assign(:results, [])
              |> assign(:total_count, 0)
              |> assign(:searched?, false)
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

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:total_count, 0)
     |> assign(:searched?, false)
     |> assign(:suggestions, [])
     |> assign(:show_suggestions, false)
     |> assign(:command_mode, false)
     |> push_patch(to: ~p"/maid")}
  end

  def handle_event("set_lens", %{"lens" => lens}, socket) do
    lens = normalize_lens(lens)
    query = socket.assigns.query

    if query == "" do
      {:noreply, assign(socket, :active_lens, lens)}
    else
      {:noreply, push_patch(socket, to: search_path(query, lens))}
    end
  end

  defp handle_command_submit(socket, query) do
    case Search.execute_action(socket.assigns.current_user, query, source: "search_live") do
      {:ok, %{mode: :navigate, url: url}} when is_binary(url) ->
        if Elektrine.Strings.present?(url) do
          {:noreply, push_navigate(socket, to: url)}
        else
          {:noreply, socket}
        end

      {:ok, %{mode: :operation, message: message, url: url}}
      when is_binary(url) ->
        if Elektrine.Strings.present?(url) do
          {:noreply, socket |> put_flash(:info, message) |> push_navigate(to: url)}
        else
          {:noreply, socket |> put_flash(:info, message) |> perform_search(query)}
        end

      {:ok, %{mode: :operation, message: message}} ->
        {:noreply, socket |> put_flash(:info, message) |> perform_search(query)}

      {:error, :unknown_action} ->
        socket = perform_search(socket, query)
        {:noreply, push_patch(socket, to: search_path(query, socket.assigns.active_lens))}

      {:error, :insufficient_scope} ->
        {:noreply, put_flash(socket, :error, "This action is not allowed for this token scope.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Action could not be executed right now.")}
    end
  end

  defp perform_search(socket, query, opts \\ []) do
    user = socket.assigns.current_user
    include_web? = Keyword.get(opts, :include_web?, true)
    lens = Keyword.get(opts, :lens, socket.assigns.active_lens) |> normalize_lens()
    web_search_allowed? = web_search_allowed?(user)

    socket
    |> assign(:loading, true)
    |> assign(:query, query)
    |> assign(:command_mode, String.starts_with?(query, ">"))
    |> assign(:active_lens, lens)
    |> then(fn socket ->
      search_results =
        merged_search(user, query,
          limit: lens_limit(lens),
          include_web?: include_web? and web_search_allowed?,
          lens: lens
        )

      socket
      |> assign(:results, search_results.results)
      |> assign(:total_count, search_results.total_count)
      |> assign(:web_search_allowed?, web_search_allowed?)
      |> assign(:searched?, true)
      |> assign(:loading, false)
      |> assign(:show_suggestions, false)
    end)
  end

  defp assign_pending_query(socket, query) do
    socket
    |> assign(:query, query)
    |> assign(:results, [])
    |> assign(:total_count, 0)
    |> assign(:searched?, false)
  end

  defp allow_search_request(socket, event_type) do
    user_id = socket.assigns.current_user && socket.assigns.current_user.id

    if is_nil(user_id) do
      :ok
    else
      rate_limit_key = "search:#{event_type}:#{user_id}"

      try do
        SearchRateLimiter.allow_query(rate_limit_key)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp get_suggestions(%{assigns: %{current_user: nil}}, _query), do: []

  defp get_suggestions(socket, query),
    do: Search.get_suggestions(socket.assigns.current_user, query, 8)

  defp search_path(query, lens) do
    params =
      [q: query]
      |> maybe_put_lens_param(lens)

    "/maid?" <> URI.encode_query(params)
  end

  defp maybe_put_lens_param(params, lens) when lens in [nil, "", "all"], do: params
  defp maybe_put_lens_param(params, lens), do: Keyword.put(params, :lens, lens)

  defp assign_web_search_access(socket) do
    socket
    |> assign(:web_search_allowed?, web_search_allowed?(socket.assigns[:current_user]))
    |> assign(:web_search_min_trust_level, Elektrine.System.module_min_trust_level(:maid))
  end

  defp web_search_allowed?(user), do: Elektrine.System.user_can_access_module?(user, :maid)

  defp merged_search(user, query, opts) do
    limit = Keyword.fetch!(opts, :limit)
    include_web? = Keyword.get(opts, :include_web?, true)
    lens = Keyword.get(opts, :lens, "all") |> normalize_lens()

    app_results = app_search(user, query, limit, lens)
    web_results = external_search(query, limit, lens, include_web?)

    app_results = apply_lens_to_app_results(app_results.results, lens)

    results =
      (app_results ++ web_results)
      |> Enum.sort_by(&(-Map.get(&1, :relevance, 0)))
      |> Enum.take(limit)

    %{results: results, total_count: length(app_results) + length(web_results)}
  end

  defp app_search(nil, _query, _limit, _lens), do: %{results: [], total_count: 0}

  defp app_search(_user, _query, _limit, lens)
       when lens in ["web", "images", "videos", "news"],
       do: %{results: [], total_count: 0}

  defp app_search(user, query, limit, _lens), do: Search.global_search(user, query, limit: limit)

  defp external_search(_query, _limit, _lens, false), do: []

  defp external_search(_query, _limit, lens, true)
       when lens in ["elektrine", "forums"],
       do: []

  defp external_search(query, limit, "images", true),
    do: search_external(query, min(limit, 200), :images)

  defp external_search(query, limit, "videos", true),
    do: search_external(query, min(limit, 50), :videos)

  defp external_search(query, limit, "news", true),
    do: search_external(query, min(limit, 50), :news)

  defp external_search(query, limit, "all", true) do
    web_limit = max(limit - 8, 1)

    search_external(query, min(web_limit, 20), :web) ++
      search_external(query, 12, :images) ++
      search_external(query, 12, :videos)
  end

  defp external_search(query, limit, "web", true),
    do: search_external(query, min(limit, 20), :web)

  defp external_search(query, limit, _lens, true),
    do: search_external(query, min(limit, 20), :web)

  defp apply_lens_to_app_results(results, "elektrine"), do: results

  defp apply_lens_to_app_results(results, "forums"),
    do: Enum.filter(results, &(&1.type in ["discussion", "community", "federated"]))

  defp apply_lens_to_app_results(_results, lens)
       when lens in ["web", "images", "videos", "news"],
       do: []

  defp apply_lens_to_app_results(results, _lens), do: results

  defp search_external(query, limit, kind) do
    query = String.trim(query || "")

    cond do
      String.length(query) < 2 ->
        []

      String.starts_with?(query, ">") ->
        []

      true ->
        case Maid.search(query, limit: limit, kind: kind) do
          {:ok, results} ->
            results
            |> Enum.with_index()
            |> Enum.map(fn {result, index} -> external_result(result, index, kind) end)

          {:error, _reason} ->
            []
        end
    end
  rescue
    _error -> []
  end

  defp external_result(result, index, kind) do
    %{
      id: "#{kind}-#{index}-#{:erlang.phash2(result.url)}",
      type: external_result_type(result, kind),
      title: result.title,
      content: result.snippet,
      url: result.url,
      updated_at: result.published_at,
      source: result.source,
      image_url: result.metadata[:image_url],
      duration: result.metadata[:duration],
      publisher: result.metadata[:publisher],
      relevance: external_relevance(kind, index)
    }
  end

  defp external_relevance(:web, index), do: 0.6 - index / 1000
  defp external_relevance(:images, index), do: 0.45 - index / 1000
  defp external_relevance(:videos, index), do: 0.44 - index / 1000
  defp external_relevance(:news, index), do: 0.5 - index / 1000

  defp external_result_type(_result, :images), do: "image"
  defp external_result_type(_result, :videos), do: "video"
  defp external_result_type(_result, :news), do: "news"
  defp external_result_type(_result, _kind), do: "web"

  defp normalize_lens(lens) when is_binary(lens) do
    lens = String.downcase(String.trim(lens))

    if lens in lens_ids(), do: lens, else: "all"
  end

  defp normalize_lens(_lens), do: "all"

  defp lens_ids,
    do: ["all", "elektrine", "web", "images", "videos", "news", "forums"]

  defp lens_limit("images"), do: 200
  defp lens_limit(lens) when lens in ["web", "videos", "news"], do: 50
  defp lens_limit(_lens), do: 50

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl px-4 pb-8 sm:px-6 lg:px-8">
      <.e_nav active_tab="maid" current_user={@current_user} />

      <div class="space-y-6">
        <section class="card panel-card overflow-visible shadow-sm">
          <div class={[
            "card-body",
            if(@query == "", do: "px-4 py-10 sm:px-8 sm:py-14", else: "p-4 sm:p-5")
          ]}>
            <div class={[
              "mx-auto",
              if(@query == "", do: "max-w-3xl text-center", else: "max-w-5xl")
            ]}>
              <div :if={@query == ""} class="mb-8 space-y-3">
                <p class="text-xs font-semibold uppercase tracking-[0.28em] text-base-content/45">
                  Search
                </p>
                <h1 class="text-4xl font-black tracking-tight text-base-content sm:text-6xl">
                  Maid
                </h1>
                <p class="mx-auto max-w-2xl text-sm leading-6 text-base-content/65 sm:text-base">
                  {maid_intro(@web_search_allowed?)}
                </p>
              </div>

              <div class="relative" phx-click-away="clear_suggestions">
                <form phx-submit="search" class="w-full">
                  <div class="join flex w-full">
                    <label class="input input-bordered join-item flex min-w-0 flex-1 items-center gap-2 rounded-l-full rounded-r-none">
                      <.icon name="hero-magnifying-glass" class="h-4 w-4 opacity-60" />
                      <input
                        id="global-search-input"
                        type="text"
                        name="query"
                        value={@query}
                        placeholder="Maid..."
                        class="grow bg-transparent"
                        autocomplete="off"
                      />

                      <button
                        type="button"
                        phx-click="clear_search"
                        data-search-clear="true"
                        aria-label="Clear search"
                        class={[
                          "btn btn-ghost btn-xs",
                          if(@query == "", do: "pointer-events-none invisible", else: nil)
                        ]}
                      >
                        <.icon name="hero-x-mark" class="h-4 w-4" />
                      </button>
                    </label>

                    <button
                      type="submit"
                      class="btn btn-outline join-item rounded-l-none rounded-r-full px-4"
                      aria-label="Search"
                      title="Search"
                    >
                      <.icon name="hero-magnifying-glass" class="h-4 w-4" />
                    </button>
                  </div>
                </form>

                <%= if @show_suggestions and @suggestions != [] do %>
                  <div class="dropdown-content absolute left-0 right-0 z-30 mt-2 overflow-hidden rounded-lg">
                    <%= for suggestion <- @suggestions do %>
                      <button
                        type="button"
                        class="flex w-full items-center justify-between gap-3 border-b border-[color:var(--surface-floating-border)] px-5 py-3 text-left transition-colors last:border-b-0 hover:bg-[color-mix(in_srgb,var(--surface-floating-bg-fallback)_82%,var(--color-base-300)_18%)]"
                        phx-click="search"
                        phx-value-query={suggestion.text}
                      >
                        <span class="truncate text-sm font-medium">{suggestion.text}</span>
                        <span class="badge badge-ghost badge-sm shrink-0">
                          {format_suggestion_type(suggestion.type)}
                        </span>
                      </button>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <div class="mt-4">
                <.pill_switcher
                  event="set_lens"
                  param="lens"
                  active={@active_lens}
                  options={lenses(@web_search_allowed?)}
                />
              </div>

              <div
                :if={web_search_locked?(@active_lens, @web_search_allowed?)}
                class="mt-4 rounded-xl border border-warning/30 bg-warning/10 p-4 text-left text-sm text-base-content/75"
              >
                <div class="flex gap-3">
                  <.icon name="hero-lock-closed" class="mt-0.5 h-5 w-5 shrink-0 text-warning" />
                  <div>
                    <p class="font-semibold text-base-content">Web search is trust-walled</p>
                    <p>
                      Admin settings require TL{@web_search_min_trust_level}+ for web, image,
                      video, and news search. Maid app search is still available.
                    </p>
                  </div>
                </div>
              </div>

              <div class="mt-4 flex flex-wrap items-center gap-2">
                <span class="hidden text-xs font-semibold uppercase tracking-[0.18em] text-base-content/40 sm:inline">
                  Quick actions
                </span>
                <button
                  class="btn btn-sm btn-ghost rounded-full"
                  phx-click="search"
                  phx-value-query=">compose email"
                >
                  Compose Email
                </button>
                <button
                  class="btn btn-sm btn-ghost rounded-full"
                  phx-click="search"
                  phx-value-query=">open chat"
                >
                  Open Chat
                </button>
                <button
                  class="btn btn-sm btn-ghost rounded-full"
                  phx-click="search"
                  phx-value-query=">open notifications"
                >
                  Notifications
                </button>
                <button
                  class="btn btn-sm btn-ghost rounded-full"
                  phx-click="search"
                  phx-value-query="settings"
                >
                  Settings
                </button>
              </div>
            </div>
          </div>
        </section>

        <%= if @loading do %>
          <div class="flex justify-center py-8">
            <.spinner size="md" class="text-primary" />
          </div>
        <% end %>

        <%= if not @loading and @searched? do %>
          <%= if @results != [] do %>
            <div class="w-full space-y-3">
              <div class="flex flex-wrap items-center justify-between gap-3 border-b border-[color:var(--surface-panel-border)] pb-2 text-sm text-base-content/65">
                <p>
                  About <span class="font-semibold text-base-content">{@total_count}</span>
                  result{plural_suffix(@total_count)} for
                  <span class="font-semibold text-base-content">{@query}</span>
                </p>
                <span :if={@command_mode} class="badge badge-neutral badge-sm">Command mode</span>
              </div>

              <.lens_results results={@results} active_lens={@active_lens} />
            </div>
          <% else %>
            <div class="card panel-card">
              <div class="card-body p-4 sm:p-5">
                <div class="flex items-start gap-3 text-sm text-base-content/65">
                  <span class="surface-subtle mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded text-base-content/45">
                    <.icon name="hero-magnifying-glass" class="h-4 w-4" />
                  </span>
                  <div>
                    <h2 class="font-semibold text-base-content">No matches found</h2>
                    <p>{lens_empty_description(@active_lens)}</p>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        <% end %>

        <%= if @query == "" and not @loading do %>
          <div class="grid gap-4 md:grid-cols-3">
            <button
              class="card panel-card text-left shadow-sm transition hover:border-base-content/20"
              phx-click="search"
              phx-value-query="people"
            >
              <div class="card-body gap-2 p-4 sm:p-5">
                <.icon name="hero-user-circle" class="h-6 w-6 text-base-content/70" />
                <h2 class="font-semibold">People and profiles</h2>
                <p class="text-sm text-base-content/65">
                  Find local people, federated actors, and profile settings.
                </p>
              </div>
            </button>
            <button
              class="card panel-card text-left shadow-sm transition hover:border-base-content/20"
              phx-click="search"
              phx-value-query="email"
            >
              <div class="card-body gap-2 p-4 sm:p-5">
                <.icon name="hero-envelope" class="h-6 w-6 text-base-content/70" />
                <h2 class="font-semibold">Mail and files</h2>
                <p class="text-sm text-base-content/65">
                  Search inboxes, attachments, drive entries, and app content.
                </p>
              </div>
            </button>
            <button
              :if={@web_search_allowed?}
              class="card panel-card text-left shadow-sm transition hover:border-base-content/20"
              phx-click="search"
              phx-value-query="web search"
            >
              <div class="card-body gap-2 p-4 sm:p-5">
                <.icon name="hero-globe-alt" class="h-6 w-6 text-base-content/70" />
                <h2 class="font-semibold">Web</h2>
                <p class="text-sm text-base-content/65">
                  Search across the wider web.
                </p>
              </div>
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions for formatting
  defp lenses(web_search_allowed?) do
    base_lenses = [
      %{value: "all", label: "All", icon: "hero-sparkles"},
      %{
        value: "elektrine",
        label: "Elektrine",
        icon: "hero-bolt"
      },
      %{
        value: "forums",
        label: "Forums",
        icon: "hero-chat-bubble-bottom-center-text"
      }
    ]

    web_lenses = [
      %{value: "web", label: "Web", icon: "hero-globe-alt"},
      %{value: "images", label: "Images", icon: "hero-photo"},
      %{value: "videos", label: "Videos", icon: "hero-play-circle"},
      %{value: "news", label: "News", icon: "hero-newspaper"}
    ]

    if web_search_allowed?, do: base_lenses ++ web_lenses, else: base_lenses
  end

  defp maid_intro(true), do: "Search Elektrine, the web, and focused lenses."
  defp maid_intro(false), do: "Search Elektrine and focused lenses."

  defp web_search_locked?(lens, false), do: lens in ["web", "images", "videos", "news"]
  defp web_search_locked?(_lens, _web_search_allowed?), do: false

  defp lens_empty_description("forums") do
    "No matching Elektrine discussions or communities yet."
  end

  defp lens_empty_description(_lens) do
    "Try a broader query or use `>` for commands."
  end

  attr :results, :list, required: true
  attr :active_lens, :string, required: true

  defp lens_results(%{active_lens: "images"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 2xl:grid-cols-5">
      <%= for result <- @results do %>
        <a
          href={result.url}
          target="_blank"
          rel="noopener noreferrer"
          class="group card panel-card overflow-hidden transition hover:border-base-content/20"
        >
          <div class="surface-subtle aspect-video">
            <img
              :if={result[:image_url]}
              src={result.image_url}
              alt={result.title}
              class="h-full w-full object-cover"
              loading="lazy"
            />
            <div
              :if={!result[:image_url]}
              class="flex h-full items-center justify-center text-base-content/40"
            >
              <.icon name="hero-photo" class="h-10 w-10" />
            </div>
          </div>
          <div class="min-h-20 space-y-1 p-3">
            <p class="line-clamp-2 text-sm font-semibold group-hover:underline">{result.title}</p>
            <p class="truncate text-xs text-base-content/50">{display_url(result.url)}</p>
          </div>
        </a>
      <% end %>
    </div>
    """
  end

  defp lens_results(%{active_lens: "videos"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
      <%= for result <- @results do %>
        <a
          href={result.url}
          target="_blank"
          rel="noopener noreferrer"
          class="group card panel-card overflow-hidden transition hover:border-base-content/20"
        >
          <div class="surface-subtle aspect-video">
            <img
              :if={result[:image_url]}
              src={result.image_url}
              alt=""
              class="h-full w-full object-cover"
              loading="lazy"
            />
            <div
              :if={!result[:image_url]}
              class="flex h-full items-center justify-center text-base-content/40"
            >
              <.icon name="hero-play-circle" class="h-10 w-10" />
            </div>
          </div>
          <div class="min-h-20 space-y-1 p-3">
            <p class="line-clamp-2 text-sm font-semibold group-hover:underline">
              {plain_text(result.title)}
            </p>
            <p class="truncate text-xs text-base-content/50">{display_url(result.url)}</p>
          </div>
        </a>
      <% end %>
    </div>
    """
  end

  defp lens_results(%{active_lens: lens} = assigns) when lens in ["all", "web"] do
    ~H"""
    <% normal_results = non_media_results(@results) %>
    <% first_results = Enum.take(normal_results, 3) %>
    <% middle_results = normal_results |> Enum.drop(3) |> Enum.take(4) %>
    <% rest_results = Enum.drop(normal_results, 7) %>

    <div class="space-y-3">
      <.result_list :if={first_results != []} results={first_results} />

      <.media_strip
        :if={image_results(@results) != []}
        title="Images"
        results={image_results(@results)}
      />

      <.result_list :if={middle_results != []} results={middle_results} />

      <.media_strip
        :if={video_results(@results) != []}
        title="Videos"
        results={video_results(@results)}
      />

      <.result_list :if={rest_results != []} results={rest_results} />
    </div>
    """
  end

  defp lens_results(assigns) do
    ~H"""
    <.result_list results={@results} />
    """
  end

  attr :results, :list, required: true

  defp result_list(assigns) do
    ~H"""
    <div class="card panel-card overflow-hidden">
      <div class="divide-y divide-base-300">
        <%= for result <- @results do %>
          <.search_result_link result={result} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :results, :list, required: true

  defp media_strip(assigns) do
    ~H"""
    <section class="card panel-card">
      <div class="card-body gap-3 p-4">
        <h2 class="text-sm font-semibold text-base-content">{@title}</h2>
        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <a
            :for={result <- @results}
            href={result.url}
            target="_blank"
            rel="noopener noreferrer"
            class="group min-w-0"
          >
            <div class="surface-subtle aspect-video overflow-hidden rounded">
              <img
                :if={result[:image_url]}
                src={result.image_url}
                alt=""
                class="h-full w-full object-cover transition group-hover:scale-[1.02]"
                loading="lazy"
              />
              <div
                :if={!result[:image_url]}
                class="flex h-full items-center justify-center text-base-content/40"
              >
                <.icon name={result_icon(result.type)} class="h-8 w-8" />
              </div>
            </div>
            <p class="mt-2 line-clamp-2 text-sm font-medium leading-5 group-hover:underline">
              {plain_text(result.title)}
            </p>
            <p class="truncate text-xs text-base-content/50">{display_url(result.url)}</p>
          </a>
        </div>
      </div>
    </section>
    """
  end

  defp image_results(results), do: results |> Enum.filter(&(&1.type == "image")) |> Enum.take(8)
  defp video_results(results), do: results |> Enum.filter(&(&1.type == "video")) |> Enum.take(8)
  defp non_media_results(results), do: Enum.reject(results, &(&1.type in ["image", "video"]))

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
  defp format_result_type("web"), do: "Web"
  defp format_result_type("image"), do: "Image"
  defp format_result_type("video"), do: "Video"
  defp format_result_type("news"), do: "News"
  defp format_result_type(_), do: "Other"

  defp format_suggestion_type("action"), do: "action"
  defp format_suggestion_type("settings"), do: "settings"
  defp format_suggestion_type("person"), do: "person"
  defp format_suggestion_type("email_domain"), do: "domain"
  defp format_suggestion_type(_), do: "other"

  defp type_badge_class("web"), do: "badge-outline"
  defp type_badge_class(_type), do: "badge-ghost"

  attr :result, :map, required: true

  defp search_result_link(%{result: %{type: "web"}} = assigns) do
    ~H"""
    <a
      href={@result.url}
      target="_blank"
      rel="noopener noreferrer"
      class="group block px-4 py-3 transition hover:bg-[color-mix(in_srgb,var(--surface-panel-bg-fallback)_82%,var(--color-base-300)_18%)] sm:px-5"
    >
      <.search_result_content result={@result} />
    </a>
    """
  end

  defp search_result_link(assigns) do
    ~H"""
    <.link
      navigate={@result.url}
      class="group block px-4 py-3 transition hover:bg-[color-mix(in_srgb,var(--surface-panel-bg-fallback)_82%,var(--color-base-300)_18%)] sm:px-5"
    >
      <.search_result_content result={@result} />
    </.link>
    """
  end

  attr :result, :map, required: true

  defp search_result_content(assigns) do
    ~H"""
    <article class="flex min-w-0 gap-3">
      <div class="surface-subtle mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center overflow-hidden rounded text-base-content/60">
        <img
          :if={favicon_url(@result.url)}
          src={favicon_url(@result.url)}
          alt=""
          class="h-5 w-5"
          loading="lazy"
        />
        <.icon :if={!favicon_url(@result.url)} name={result_icon(@result.type)} class="h-4 w-4" />
      </div>

      <div class="min-w-0 flex-1 space-y-1">
        <div class="flex min-w-0 items-center gap-2 text-xs text-base-content/55">
          <span class="shrink-0 font-semibold text-base-content/75">
            {plain_text(result_source_label(@result))}
          </span>
          <span class="min-w-0 truncate">{display_url(@result.url)}</span>
          <span class={"badge badge-xs shrink-0 " <> type_badge_class(@result.type)}>
            {format_result_type(@result.type)}
          </span>
        </div>

        <h2 class="text-base font-semibold leading-snug text-base-content group-hover:underline sm:text-lg">
          {plain_text(@result.title)}
        </h2>

        <%= if plain_text(@result.content) != "" do %>
          <p class="line-clamp-2 text-sm leading-5 text-base-content/72">
            {plain_text(@result.content)}
          </p>
        <% end %>

        <div class="flex flex-wrap items-center gap-2 text-xs text-base-content/45">
          <span>{format_result_meta(@result)}</span>
          <%= if @result.type == "federated" && @result[:actor_domain] do %>
            <span>{@result.actor_domain}</span>
          <% end %>
        </div>
      </div>

      <img
        :if={@result[:image_url] && @result.type != "image"}
        src={@result.image_url}
        alt=""
        class="hidden h-20 w-28 shrink-0 rounded object-cover sm:block"
        loading="lazy"
      />
    </article>
    """
  end

  defp result_icon("action"), do: "hero-command-line"
  defp result_icon("settings"), do: "hero-cog-6-tooth"
  defp result_icon("person"), do: "hero-user-circle"
  defp result_icon("chat"), do: "hero-chat-bubble-left-right"
  defp result_icon("timeline"), do: "hero-rectangle-stack"
  defp result_icon("discussion"), do: "hero-chat-bubble-bottom-center-text"
  defp result_icon("community"), do: "hero-user-group"
  defp result_icon("federated"), do: "hero-globe-alt"
  defp result_icon("email"), do: "hero-envelope"
  defp result_icon("file"), do: "hero-document"
  defp result_icon("mailbox"), do: "hero-inbox"
  defp result_icon("web"), do: "hero-globe-alt"
  defp result_icon("image"), do: "hero-photo"
  defp result_icon("video"), do: "hero-play-circle"
  defp result_icon("news"), do: "hero-newspaper"
  defp result_icon(_type), do: "hero-sparkles"

  defp result_source_label(%{type: "news", publisher: publisher})
       when is_binary(publisher) and publisher != "" do
    publisher
  end

  defp result_source_label(%{type: type, url: url})
       when type in ["web", "image", "video", "news"] do
    result_host(url) || format_result_type(type)
  end

  defp result_source_label(%{type: type}), do: "Elektrine #{format_result_type(type)}"

  defp result_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        String.replace_prefix(String.downcase(host), "www.", "")

      _uri ->
        nil
    end
  end

  defp result_host(_url), do: nil

  defp favicon_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        "https://icons.duckduckgo.com/ip3/#{String.downcase(host)}.ico"

      _uri ->
        nil
    end
  end

  defp favicon_url(_url), do: nil

  defp display_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) ->
        path = path || "/"
        host <> shorten_path(path)

      %URI{path: path} when is_binary(path) ->
        path

      _uri ->
        url
    end
  end

  defp display_url(url), do: to_string(url || "")

  defp shorten_path(path) when byte_size(path) > 42, do: String.slice(path, 0, 39) <> "..."
  defp shorten_path(path), do: path

  defp plain_text(value) when is_binary(value) do
    value
    |> HtmlEntities.decode()
    |> HtmlSanitizeEx.strip_tags()
    |> HtmlEntities.decode()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp plain_text(_value), do: ""

  defp format_result_meta(%{type: "web"}), do: "Web"

  defp format_result_meta(%{type: "video", duration: duration})
       when is_binary(duration) and duration != "" do
    duration
  end

  defp format_result_meta(%{type: "news", publisher: publisher})
       when is_binary(publisher) and publisher != "" do
    publisher
  end

  defp format_result_meta(result), do: format_relative_time(Map.get(result, :updated_at))

  defp plural_suffix(1), do: ""
  defp plural_suffix(_count), do: "s"

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
