defmodule ElektrineWeb.SearchLive do
  use ElektrineWeb, :live_view
  alias Elektrine.Search
  alias Elektrine.Search.DomainRules
  alias Elektrine.Search.RateLimiter, as: SearchRateLimiter
  alias Elektrine.Security.SafeExternalURL
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
     |> assign(:web_degraded?, false)
     |> assign_web_search_access()
     |> assign_domain_rules()}
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
     |> push_patch(to: ~p"/paige")}
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

  def handle_event("set_domain_rule", %{"domain" => domain, "action" => action}, socket) do
    with %{} = user <- socket.assigns.current_user,
         true <- socket.assigns.web_search_allowed?,
         {:ok, _rule} <- DomainRules.set_rule(user, domain, action) do
      {:noreply, socket |> assign_domain_rules() |> rerun_current_search()}
    else
      {:error, :rule_limit_reached} ->
        {:noreply, put_flash(socket, :error, "You have reached the domain rule limit.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the domain rule.")}
    end
  end

  def handle_event("remove_domain_rule", %{"domain" => domain}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, socket}

      user ->
        DomainRules.remove_rule(user, domain)
        {:noreply, socket |> assign_domain_rules() |> rerun_current_search()}
    end
  end

  defp handle_command_submit(socket, query) do
    case Search.execute_action(socket.assigns.current_user, query, source: "search_live") do
      {:ok, %{mode: :navigate, url: url}} when is_binary(url) ->
        if Elektrine.Strings.present?(url) do
          ElektrineWeb.SafeLiveNavigation.noreply(socket, url)
        else
          {:noreply, socket}
        end

      {:ok, %{mode: :operation, message: message, url: url}}
      when is_binary(url) ->
        if Elektrine.Strings.present?(url) do
          socket
          |> put_flash(:info, message)
          |> ElektrineWeb.SafeLiveNavigation.noreply(url)
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
          lens: lens,
          domain_rules: socket.assigns.domain_rules
        )

      socket
      |> assign(:results, search_results.results)
      |> assign(:total_count, search_results.total_count)
      |> assign(:web_degraded?, search_results.web_degraded?)
      |> assign(:web_search_allowed?, web_search_allowed?)
      |> assign(:searched?, true)
      |> assign(:loading, false)
      |> assign(:show_suggestions, false)
    end)
  end

  defp assign_domain_rules(socket) do
    user = socket.assigns[:current_user]
    assign(socket, :domain_rules, DomainRules.rules_map(user && user.id))
  end

  defp rerun_current_search(socket) do
    if socket.assigns.searched? and socket.assigns.query != "" do
      perform_search(socket, socket.assigns.query)
    else
      socket
    end
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

    "/paige?" <> URI.encode_query(params)
  end

  defp maybe_put_lens_param(params, lens) when lens in [nil, "", "all"], do: params
  defp maybe_put_lens_param(params, lens), do: Keyword.put(params, :lens, lens)

  defp assign_web_search_access(socket) do
    socket
    |> assign(:web_search_allowed?, web_search_allowed?(socket.assigns[:current_user]))
    |> assign(:web_search_min_trust_level, Elektrine.System.module_min_trust_level(:paige))
  end

  defp web_search_allowed?(user), do: Elektrine.System.user_can_access_module?(user, :paige)

  defp merged_search(user, query, opts) do
    limit = Keyword.fetch!(opts, :limit)
    include_web? = Keyword.get(opts, :include_web?, true)
    lens = Keyword.get(opts, :lens, "all") |> normalize_lens()
    domain_rules = Keyword.get(opts, :domain_rules, %{})

    app_results = app_search(user, query, limit, lens)
    {web_results, web_degraded?} = external_search(query, limit, lens, include_web?)

    app_results = apply_lens_to_app_results(app_results.results, lens)
    web_results = DomainRules.apply_rules(web_results, domain_rules)

    results =
      (app_results ++ web_results)
      |> Enum.sort_by(&(-Map.get(&1, :relevance, 0)))
      |> Enum.take(limit)

    %{
      results: results,
      total_count: length(app_results) + length(web_results),
      web_degraded?: web_degraded?
    }
  end

  defp app_search(nil, _query, _limit, _lens), do: %{results: [], total_count: 0}

  defp app_search(_user, _query, _limit, lens)
       when lens in ["web", "images", "videos", "news"],
       do: %{results: [], total_count: 0}

  defp app_search(user, query, limit, _lens), do: Search.global_search(user, query, limit: limit)

  defp external_search(_query, _limit, _lens, false), do: {[], false}

  defp external_search(_query, _limit, lens, true)
       when lens in ["elektrine", "forums"],
       do: {[], false}

  defp external_search(query, limit, "images", true),
    do: search_external(query, min(limit, 200), :images)

  defp external_search(query, limit, "videos", true),
    do: search_external(query, min(limit, 50), :videos)

  defp external_search(query, limit, "news", true),
    do: search_external(query, min(limit, 50), :news)

  defp external_search(query, limit, "all", true) do
    web_limit = max(limit - 8, 1)

    combine_external([
      search_external(query, min(web_limit, 20), :web),
      search_external(query, 12, :images),
      search_external(query, 12, :videos)
    ])
  end

  defp external_search(query, limit, "web", true),
    do: search_external(query, min(limit, 20), :web)

  defp external_search(query, limit, _lens, true),
    do: search_external(query, min(limit, 20), :web)

  defp combine_external(parts) do
    {Enum.flat_map(parts, &elem(&1, 0)), Enum.any?(parts, &elem(&1, 1))}
  end

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
        {[], false}

      String.starts_with?(query, ">") ->
        {[], false}

      true ->
        case ElektrineWeb.WebSearch.search(query, limit: limit, kind: kind) do
          {:ok, results, meta} ->
            safe_results =
              results
              |> Enum.with_index()
              |> Enum.flat_map(fn {result, index} ->
                case external_result(result, index, kind) do
                  nil -> []
                  safe_result -> [safe_result]
                end
              end)

            {safe_results, meta.degraded?}

          {:error, _reason} ->
            {[], true}
        end
    end
  rescue
    _error -> {[], true}
  end

  defp external_result(result, index, kind) do
    case SafeExternalURL.normalize_href(result.url) do
      {:ok, safe_url} ->
        %{
          id: "#{kind}-#{index}-#{:erlang.phash2(safe_url)}",
          type: external_result_type(result, kind),
          title: result.title,
          content: result.snippet,
          url: safe_url,
          updated_at: result.published_at,
          source: result.source,
          image_url: safe_optional_url(result.metadata[:image_url]),
          duration: result.metadata[:duration],
          publisher: result.metadata[:publisher],
          relevance: external_relevance(kind, index)
        }

      {:error, _reason} ->
        nil
    end
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
    <div class="mx-auto max-w-7xl px-3 pb-8 sm:px-5 lg:px-8">
      <.e_nav active_tab="paige" current_user={@current_user} />

      <%= if @query == "" do %>
        <div class="space-y-5">
          <section class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_20rem]">
            <div class="panel-card rounded-lg border border-base-300 p-4 sm:p-5">
              <div class="mb-4 flex flex-wrap items-end justify-between gap-3">
                <div>
                  <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                    Search
                  </p>
                  <h1 class="text-3xl font-bold tracking-tight text-base-content sm:text-4xl">
                    Paige
                  </h1>
                </div>
                <span class="badge badge-ghost gap-1">
                  <.icon name="hero-shield-check" class="h-3.5 w-3.5" />
                  {paige_intro(@web_search_allowed?)}
                </span>
              </div>

              <.search_form
                query={@query}
                command_mode={@command_mode}
                suggestions={@suggestions}
                show_suggestions={@show_suggestions}
                hero
              />

              <div class="mt-4">
                <.pill_switcher
                  event="set_lens"
                  param="lens"
                  active={@active_lens}
                  options={lenses(@web_search_allowed?)}
                />
              </div>

              <.trust_wall_notice
                :if={web_search_locked?(@active_lens, @web_search_allowed?)}
                min_trust_level={@web_search_min_trust_level}
                class="mt-4"
              />
            </div>

            <aside class="panel-card rounded-lg border border-base-300 p-3">
              <div class="mb-2 flex items-center justify-between">
                <h2 class="text-sm font-semibold">Launch</h2>
                <span class="text-xs text-base-content/45">Commands</span>
              </div>
              <div class="grid gap-2">
                <button
                  class={quick_action_class()}
                  phx-click="search"
                  phx-value-query=">compose email"
                >
                  <.icon name="hero-pencil-square" class="h-4 w-4 text-primary" /> Compose Email
                </button>
                <button
                  class={quick_action_class()}
                  phx-click="search"
                  phx-value-query=">open chat"
                >
                  <.icon name="hero-chat-bubble-left-right" class="h-4 w-4 text-secondary" />
                  Open Chat
                </button>
                <button
                  class={quick_action_class()}
                  phx-click="search"
                  phx-value-query=">open notifications"
                >
                  <.icon name="hero-bell" class="h-4 w-4 text-warning" /> Notifications
                </button>
                <button class={quick_action_class()} phx-click="search" phx-value-query="settings">
                  <.icon name="hero-cog-6-tooth" class="h-4 w-4 text-info" /> Settings
                </button>
              </div>
            </aside>
          </section>

          <section class="grid gap-3 md:grid-cols-3">
            <button class={starter_card_class()} phx-click="search" phx-value-query="people">
              <.icon name="hero-user-circle" class="h-5 w-5 text-primary" />
              <span>
                <span class="block font-semibold">People</span>
                <span class="block text-xs text-base-content/55">Profiles, actors, contacts</span>
              </span>
            </button>
            <button class={starter_card_class()} phx-click="search" phx-value-query="email">
              <.icon name="hero-envelope" class="h-5 w-5 text-secondary" />
              <span>
                <span class="block font-semibold">Mail and Files</span>
                <span class="block text-xs text-base-content/55">Inbox, uploads, attachments</span>
              </span>
            </button>
            <button
              :if={@web_search_allowed?}
              class={starter_card_class()}
              phx-click="search"
              phx-value-query="web search"
            >
              <.icon name="hero-globe-alt" class="h-5 w-5 text-accent" />
              <span>
                <span class="block font-semibold">Web</span>
                <span class="block text-xs text-base-content/55">Pages, images, video, news</span>
              </span>
            </button>
          </section>

          <section
            :if={@web_search_allowed? and @domain_rules != %{}}
            class="panel-card rounded-lg border border-base-300 p-4"
          >
            <div class="mb-3 flex items-center justify-between gap-3">
              <h2 class="text-sm font-semibold text-base-content">Domain rules</h2>
              <span class="badge badge-ghost badge-sm">{map_size(@domain_rules)}</span>
            </div>
            <ul class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
              <li
                :for={{domain, action} <- Enum.sort(@domain_rules)}
                class="flex min-w-0 items-center justify-between gap-3 rounded border border-base-300 px-3 py-2 text-sm"
              >
                <span class="truncate">{domain}</span>
                <span class="flex shrink-0 items-center gap-2">
                  <span class="badge badge-ghost badge-sm">{domain_rule_label(action)}</span>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs btn-square"
                    phx-click="remove_domain_rule"
                    phx-value-domain={domain}
                    aria-label={"Remove rule for #{domain}"}
                  >
                    <.icon name="hero-x-mark" class="h-4 w-4" />
                  </button>
                </span>
              </li>
            </ul>
          </section>
        </div>
      <% else %>
        <div class="grid gap-5 lg:grid-cols-[minmax(0,1fr)_18rem]">
          <div class="min-w-0 space-y-4">
            <section class="panel-card overflow-visible rounded-lg border border-base-300 p-4">
              <div class="space-y-4">
                <.search_form
                  query={@query}
                  command_mode={@command_mode}
                  suggestions={@suggestions}
                  show_suggestions={@show_suggestions}
                />

                <.pill_switcher
                  event="set_lens"
                  param="lens"
                  active={@active_lens}
                  options={lenses(@web_search_allowed?)}
                />

                <.trust_wall_notice
                  :if={web_search_locked?(@active_lens, @web_search_allowed?)}
                  min_trust_level={@web_search_min_trust_level}
                />
              </div>
            </section>

            <.results_skeleton :if={@loading} />

            <%= if not @loading and @searched? do %>
              <%= if @results != [] do %>
                <div class="w-full space-y-3">
                  <div class="flex flex-wrap items-center justify-between gap-3 border-b border-[color:var(--surface-panel-border)] pb-2 text-sm text-base-content/65">
                    <p>
                      <span class="font-semibold text-base-content">{@total_count}</span>
                      result{plural_suffix(@total_count)} for
                      <span class="font-semibold text-base-content">{@query}</span>
                    </p>
                    <span :if={@web_degraded?} class="flex items-center gap-1 text-xs text-warning">
                      <.icon name="hero-exclamation-triangle" class="h-4 w-4" />
                      Some web sources were unavailable.
                    </span>
                  </div>

                  <.lens_results
                    results={@results}
                    active_lens={@active_lens}
                    domain_rules={@domain_rules}
                    can_rank_domains?={@current_user != nil and @web_search_allowed?}
                  />
                </div>
              <% else %>
                <div class="w-full">
                  <div class="panel-card rounded-lg border border-base-300 p-4 sm:p-5">
                    <div class="flex items-start gap-3">
                      <span class="surface-subtle flex h-10 w-10 shrink-0 items-center justify-center rounded-full text-base-content/45">
                        <.icon name="hero-magnifying-glass" class="h-5 w-5" />
                      </span>
                      <div class="min-w-0 text-sm text-base-content/65">
                        <h2 class="text-base font-semibold text-base-content">
                          No matches for “{@query}”
                        </h2>
                        <p>{lens_empty_description(@active_lens)}</p>
                        <p :if={@web_degraded?} class="mt-1 text-warning">
                          Some web sources were unavailable — try again in a moment.
                        </p>
                      </div>
                    </div>

                    <div class="mt-4 flex flex-wrap gap-2">
                      <button class="btn btn-sm rounded-full" phx-click="clear_search">
                        <.icon name="hero-arrow-uturn-left" class="h-4 w-4" /> Start over
                      </button>
                      <button
                        :if={
                          @web_search_allowed? and
                            @active_lens not in ["web", "images", "videos", "news"]
                        }
                        class="btn btn-primary btn-sm rounded-full"
                        phx-click="set_lens"
                        phx-value-lens="web"
                      >
                        <.icon name="hero-globe-alt" class="h-4 w-4" /> Search the web
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>

          <aside class="space-y-3 lg:sticky lg:top-20 lg:self-start">
            <section class="panel-card rounded-lg border border-base-300 p-3">
              <h2 class="mb-2 text-sm font-semibold">Refine</h2>
              <div class="grid gap-2">
                <button class={quick_action_class()} phx-click="set_lens" phx-value-lens="all">
                  <.icon name="hero-sparkles" class="h-4 w-4" /> All results
                </button>
                <button class={quick_action_class()} phx-click="set_lens" phx-value-lens="elektrine">
                  <.icon name="hero-bolt" class="h-4 w-4" /> Elektrine only
                </button>
                <button
                  :if={@web_search_allowed?}
                  class={quick_action_class()}
                  phx-click="set_lens"
                  phx-value-lens="web"
                >
                  <.icon name="hero-globe-alt" class="h-4 w-4" /> Web only
                </button>
              </div>
            </section>

            <section
              :if={@web_search_allowed? and @domain_rules != %{}}
              class="panel-card rounded-lg border border-base-300 p-3"
            >
              <div class="mb-2 flex items-center justify-between">
                <h2 class="text-sm font-semibold">Domain rules</h2>
                <span class="badge badge-ghost badge-sm">{map_size(@domain_rules)}</span>
              </div>
              <ul class="space-y-1">
                <li
                  :for={{domain, action} <- Enum.sort(@domain_rules)}
                  class="flex items-center justify-between gap-2 rounded px-2 py-1.5 text-sm hover:bg-base-200/50"
                >
                  <span class="min-w-0 truncate">{domain}</span>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="remove_domain_rule"
                    phx-value-domain={domain}
                  >
                    {domain_rule_label(action)}
                  </button>
                </li>
              </ul>
            </section>
          </aside>
        </div>
      <% end %>
    </div>
    """
  end

  attr :query, :string, required: true
  attr :command_mode, :boolean, default: false
  attr :suggestions, :list, default: []
  attr :show_suggestions, :boolean, default: false
  attr :hero, :boolean, default: false

  defp search_form(assigns) do
    ~H"""
    <div
      id="paige-search"
      phx-hook="PaigeSearch"
      phx-click-away="clear_suggestions"
      class="relative"
    >
      <form phx-submit="search" class="w-full">
        <div class="join flex w-full">
          <label class="input input-bordered join-item flex min-w-0 flex-1 items-center gap-2 rounded-l-full rounded-r-none">
            <.icon
              name={if @command_mode, do: "hero-command-line", else: "hero-magnifying-glass"}
              class={"h-4 w-4 shrink-0 " <> if(@command_mode, do: "text-primary", else: "opacity-60")}
            />
            <input
              id="global-search-input"
              type="text"
              name="query"
              value={@query}
              placeholder="Paige..."
              class="grow bg-transparent"
              autocomplete="off"
              autofocus={@hero}
            />

            <span
              :if={@command_mode}
              class="badge badge-primary badge-sm hidden shrink-0 sm:inline-flex"
            >
              Command
            </span>
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
            class="btn btn-primary join-item rounded-l-none rounded-r-full px-4"
            aria-label="Search"
            title="Search"
          >
            <.icon name="hero-magnifying-glass" class="h-4 w-4" />
          </button>
        </div>
      </form>

      <div
        :if={@show_suggestions and @suggestions != []}
        class="dropdown-content absolute left-0 right-0 z-30 mt-2 overflow-hidden rounded-lg text-left"
      >
        <button
          :for={suggestion <- @suggestions}
          type="button"
          data-suggestion-item
          phx-click="search"
          phx-value-query={suggestion.text}
          class="flex w-full items-center gap-3 border-b border-[color:var(--surface-floating-border)] px-4 py-3 text-left transition-colors last:border-b-0 hover:bg-[color-mix(in_srgb,var(--surface-floating-bg-fallback)_82%,var(--color-base-300)_18%)] focus:bg-[color-mix(in_srgb,var(--surface-floating-bg-fallback)_82%,var(--color-base-300)_18%)] focus:outline-none"
        >
          <.icon name={suggestion_icon(suggestion.type)} class="h-4 w-4 shrink-0 opacity-50" />
          <span class="min-w-0 flex-1 truncate text-sm font-medium">{suggestion.text}</span>
          <span class="badge badge-ghost badge-sm shrink-0">
            {format_suggestion_type(suggestion.type)}
          </span>
        </button>
      </div>
    </div>
    """
  end

  attr :min_trust_level, :any, required: true
  attr :class, :string, default: nil

  defp trust_wall_notice(assigns) do
    ~H"""
    <div class={[
      "rounded-xl border border-warning/30 bg-warning/10 p-4 text-left text-sm text-base-content/75",
      @class
    ]}>
      <div class="flex gap-3">
        <.icon name="hero-lock-closed" class="mt-0.5 h-5 w-5 shrink-0 text-warning" />
        <div>
          <p class="font-semibold text-base-content">Web search is trust-walled</p>
          <p>
            Admin settings require TL{@min_trust_level}+ for web, image,
            video, and news search. Paige app search is still available.
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp results_skeleton(assigns) do
    ~H"""
    <div class="w-full space-y-3">
      <div class="skeleton h-4 w-48"></div>
      <div class="card panel-card overflow-hidden">
        <div class="divide-y divide-base-300">
          <div :for={_placeholder <- 1..5} class="flex gap-3 px-4 py-4 sm:px-5">
            <div class="skeleton h-8 w-8 shrink-0 rounded"></div>
            <div class="min-w-0 flex-1 space-y-2">
              <div class="skeleton h-3 w-40"></div>
              <div class="skeleton h-4 w-3/4"></div>
              <div class="skeleton h-3 w-full"></div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp quick_action_class do
    "btn btn-sm btn-ghost justify-start gap-2 rounded px-3"
  end

  defp starter_card_class do
    "panel-card flex min-w-0 items-center gap-3 rounded-lg border border-base-300 px-4 py-3 text-left transition hover:border-base-content/20 hover:bg-base-200/35"
  end

  defp suggestion_icon("action"), do: "hero-command-line"
  defp suggestion_icon("settings"), do: "hero-cog-6-tooth"
  defp suggestion_icon("person"), do: "hero-user-circle"
  defp suggestion_icon("email_domain"), do: "hero-at-symbol"
  defp suggestion_icon(_type), do: "hero-magnifying-glass"

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

  defp paige_intro(true), do: "Elektrine + web"
  defp paige_intro(false), do: "Elektrine"

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
  attr :domain_rules, :map, default: %{}
  attr :can_rank_domains?, :boolean, default: false

  defp lens_results(%{active_lens: "images"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 2xl:grid-cols-5">
      <%= for result <- @results do %>
        <%= if result_url = safe_optional_url(result.url) do %>
          <a
            href={result_url}
            target="_blank"
            rel="noopener noreferrer"
            class="group card panel-card overflow-hidden transition hover:border-base-content/20"
          >
            <div class="surface-subtle aspect-video">
              <%= if image_url = result_image_url(result) do %>
                <img
                  src={image_url}
                  alt={result.title}
                  class="h-full w-full object-cover"
                  loading="lazy"
                />
              <% else %>
                <div class="flex h-full items-center justify-center text-base-content/40">
                  <.icon name="hero-photo" class="h-10 w-10" />
                </div>
              <% end %>
            </div>
            <div class="min-h-20 space-y-1 p-3">
              <p class="line-clamp-2 text-sm font-semibold group-hover:underline">
                {result.title}
              </p>
              <p class="truncate text-xs text-base-content/50">{display_url(result_url)}</p>
            </div>
          </a>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp lens_results(%{active_lens: "videos"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
      <%= for result <- @results do %>
        <%= if result_url = safe_optional_url(result.url) do %>
          <a
            href={result_url}
            target="_blank"
            rel="noopener noreferrer"
            class="group card panel-card overflow-hidden transition hover:border-base-content/20"
          >
            <div class="surface-subtle aspect-video">
              <%= if image_url = result_image_url(result) do %>
                <img
                  src={image_url}
                  alt=""
                  class="h-full w-full object-cover"
                  loading="lazy"
                />
              <% else %>
                <div class="flex h-full items-center justify-center text-base-content/40">
                  <.icon name="hero-play-circle" class="h-10 w-10" />
                </div>
              <% end %>
            </div>
            <div class="min-h-20 space-y-1 p-3">
              <p class="line-clamp-2 text-sm font-semibold group-hover:underline">
                {plain_text(result.title)}
              </p>
              <p class="truncate text-xs text-base-content/50">{display_url(result_url)}</p>
            </div>
          </a>
        <% end %>
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
      <.result_list
        :if={first_results != []}
        results={first_results}
        domain_rules={@domain_rules}
        can_rank_domains?={@can_rank_domains?}
      />

      <.media_strip
        :if={image_results(@results) != []}
        title="Images"
        results={image_results(@results)}
      />

      <.result_list
        :if={middle_results != []}
        results={middle_results}
        domain_rules={@domain_rules}
        can_rank_domains?={@can_rank_domains?}
      />

      <.media_strip
        :if={video_results(@results) != []}
        title="Videos"
        results={video_results(@results)}
      />

      <.result_list
        :if={rest_results != []}
        results={rest_results}
        domain_rules={@domain_rules}
        can_rank_domains?={@can_rank_domains?}
      />
    </div>
    """
  end

  defp lens_results(assigns) do
    ~H"""
    <.result_list
      results={@results}
      domain_rules={@domain_rules}
      can_rank_domains?={@can_rank_domains?}
    />
    """
  end

  attr :results, :list, required: true
  attr :domain_rules, :map, default: %{}
  attr :can_rank_domains?, :boolean, default: false

  defp result_list(assigns) do
    ~H"""
    <div class="card panel-card overflow-visible">
      <div class="divide-y divide-base-300 [&>*:first-child]:rounded-t-[var(--radius-box)] [&>*:last-child]:rounded-b-[var(--radius-box)]">
        <%= for result <- @results do %>
          <.search_result_link
            result={result}
            domain_rules={@domain_rules}
            can_rank_domains?={@can_rank_domains?}
          />
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
          <%= for result <- @results do %>
            <%= if result_url = safe_optional_url(result.url) do %>
              <a
                href={result_url}
                target="_blank"
                rel="noopener noreferrer"
                class="group min-w-0"
              >
                <div class="surface-subtle aspect-video overflow-hidden rounded">
                  <%= if image_url = result_image_url(result) do %>
                    <img
                      src={image_url}
                      alt=""
                      class="h-full w-full object-cover transition group-hover:scale-[1.02]"
                      loading="lazy"
                    />
                  <% else %>
                    <div class="flex h-full items-center justify-center text-base-content/40">
                      <.icon name={result_icon(result.type)} class="h-8 w-8" />
                    </div>
                  <% end %>
                </div>
                <p class="mt-2 line-clamp-2 text-sm font-medium leading-5 group-hover:underline">
                  {plain_text(result.title)}
                </p>
                <p class="truncate text-xs text-base-content/50">{display_url(result_url)}</p>
              </a>
            <% end %>
          <% end %>
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
  attr :domain_rules, :map, default: %{}
  attr :can_rank_domains?, :boolean, default: false

  defp search_result_link(%{result: %{type: type}} = assigns)
       when type in ["web", "news", "image", "video"] do
    ~H"""
    <%= if result_url = safe_optional_url(@result.url) do %>
      <% result = Map.put(@result, :url, result_url) %>
      <div class="group flex items-start transition hover:bg-[color-mix(in_srgb,var(--surface-panel-bg-fallback)_82%,var(--color-base-300)_18%)]">
        <a
          href={result_url}
          target="_blank"
          rel="noopener noreferrer"
          class="block min-w-0 flex-1 px-4 py-3 sm:px-5"
        >
          <.search_result_content result={result} />
        </a>
        <.domain_rule_menu
          :if={@can_rank_domains?}
          domain={result_host(result_url)}
          rules={@domain_rules}
        />
      </div>
    <% end %>
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

  attr :domain, :string, required: true
  attr :rules, :map, required: true

  defp domain_rule_menu(assigns) do
    assigns = assign(assigns, :current, Map.get(assigns.rules, assigns.domain))

    ~H"""
    <div :if={@domain} class="dropdown dropdown-end mr-2 mt-2 shrink-0 sm:mr-3">
      <button
        tabindex="0"
        type="button"
        class="btn btn-ghost btn-xs btn-square text-base-content/45 transition hover:text-base-content"
        aria-label={"Adjust ranking for #{@domain}"}
        title={"Adjust ranking for #{@domain}"}
      >
        <.icon name="hero-adjustments-horizontal" class="h-4 w-4" />
      </button>
      <ul
        tabindex="0"
        class="dropdown-content menu z-40 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
      >
        <li class="menu-title truncate">{@domain}</li>
        <li :for={{action, label, icon} <- domain_rule_actions()}>
          <button
            type="button"
            phx-click="set_domain_rule"
            phx-value-domain={@domain}
            phx-value-action={action}
            class={@current == action && "active"}
          >
            <.icon name={icon} class="h-4 w-4" /> {label}
          </button>
        </li>
        <li :if={@current}>
          <button type="button" phx-click="remove_domain_rule" phx-value-domain={@domain}>
            <.icon name="hero-x-mark" class="h-4 w-4" /> Clear rule
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp domain_rule_actions do
    [
      {:pin, "Pin domain", "hero-star"},
      {:raise, "Raise ranking", "hero-arrow-up"},
      {:lower, "Lower ranking", "hero-arrow-down"},
      {:block, "Block domain", "hero-no-symbol"}
    ]
  end

  defp domain_rule_label(:pin), do: "Pinned"
  defp domain_rule_label(:raise), do: "Raised"
  defp domain_rule_label(:lower), do: "Lowered"
  defp domain_rule_label(:block), do: "Blocked"

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

      <%= if thumbnail_url = result_thumbnail_url(@result) do %>
        <img
          src={thumbnail_url}
          alt=""
          class="hidden h-20 w-28 shrink-0 rounded object-cover sm:block"
          loading="lazy"
        />
      <% end %>
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

  defp result_thumbnail_url(%{type: "image"}), do: nil

  defp result_thumbnail_url(result) do
    result_image_url(result)
  end

  defp result_image_url(result) do
    ElektrineWeb.HtmlHelpers.safe_external_image_url(result[:image_url])
  end

  defp safe_optional_url(nil), do: nil

  defp safe_optional_url(url) do
    case SafeExternalURL.normalize_href(url) do
      {:ok, safe_url} -> safe_url
      {:error, _reason} -> nil
    end
  end
end
