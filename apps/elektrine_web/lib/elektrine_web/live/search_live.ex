defmodule ElektrineWeb.SearchLive do
  use ElektrineWeb, :live_view
  alias Elektrine.Search
  alias Elektrine.Search.DomainRules
  alias Elektrine.Search.PaigeRateLimiter
  alias Elektrine.Search.RateLimiter, as: SearchRateLimiter
  alias Elektrine.Security.SafeExternalURL
  import ElektrineWeb.Components.Platform.ENav

  @max_query_length 400

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:draft_query, "")
     |> assign(:results, [])
     |> assign(:total_count, 0)
     |> assign(:searched?, false)
     |> assign(:loading, false)
     |> assign(:search_request_id, nil)
     |> assign(:search_status, :idle)
     |> assign(:search_error, nil)
     |> assign(:search_retry_after, nil)
     |> assign(:suggestions, [])
     |> assign(:show_suggestions, false)
     |> assign(:active_lens, "all")
     |> assign(:page, 1)
     |> assign(:freshness, "all")
     |> assign(:safesearch, "moderate")
     |> assign(:has_more?, false)
     |> assign(:command_mode, false)
     |> assign(:web_degraded?, false)
     |> assign(:web_available?, true)
     |> assign(:failed_providers, [])
     |> assign(:successful_providers, [])
     |> assign(:provider_stats, [])
     |> assign(:paige_rate_limit_identifier, paige_rate_limit_identifier(socket))
     |> assign_web_search_access()
     |> assign_domain_rules()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = String.trim(params["q"] || "")
    lens = normalize_lens(params["lens"])
    page = normalize_page(params["page"])
    freshness = normalize_freshness(params["freshness"])
    safesearch = normalize_safesearch(params["safesearch"])

    socket =
      socket
      |> assign_web_search_access()
      |> assign(:active_lens, lens)
      |> assign(:page, page)
      |> assign(:freshness, freshness)
      |> assign(:safesearch, safesearch)

    cond do
      query_too_long?(query) ->
        {:noreply, invalid_query(socket, query)}

      String.length(query) >= 2 ->
        {:noreply,
         start_search(socket, query,
           lens: lens,
           page: page,
           freshness: freshness,
           safesearch: safesearch
         )}

      true ->
        {:noreply, reset_search(socket, query)}
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    if query_too_long?(query) do
      {:noreply, invalid_query(socket, query)}
    else
      handle_search_submit(socket, query)
    end
  end

  def handle_event("suggest", %{"query" => query}, socket) do
    query = String.trim(query)

    case allow_search_request(socket, :suggest) do
      :ok ->
        socket =
          if String.length(query) >= 2 do
            suggestions = get_suggestions(socket, query)

            socket
            |> assign(:draft_query, query)
            |> assign(:suggestions, suggestions)
            |> assign(:show_suggestions, suggestions != [])
            |> assign(:command_mode, String.starts_with?(query, ">"))
          else
            if String.starts_with?(query, ">") do
              suggestions = get_suggestions(socket, query)

              socket
              |> assign(:draft_query, query)
              |> assign(:suggestions, suggestions)
              |> assign(:show_suggestions, suggestions != [])
              |> assign(:command_mode, true)
            else
              socket
              |> assign(:draft_query, query)
              |> assign(:suggestions, [])
              |> assign(:show_suggestions, false)
              |> assign(:command_mode, false)
            end
          end

        {:noreply, socket}

      {:error, _retry_after} ->
        {:noreply,
         socket
         |> assign(:draft_query, query)
         |> assign(:show_suggestions, false)
         |> assign(:suggestions, [])}
    end
  end

  def handle_event("suggest", %{"value" => query}, socket),
    do: handle_event("suggest", %{"query" => query}, socket)

  def handle_event("clear_suggestions", _params, socket) do
    {:noreply, assign(socket, :show_suggestions, false)}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:query, "")
     |> assign(:draft_query, "")
     |> assign(:results, [])
     |> assign(:total_count, 0)
     |> assign(:searched?, false)
     |> assign(:loading, false)
     |> assign(:search_request_id, nil)
     |> assign(:search_status, :idle)
     |> assign(:search_error, nil)
     |> assign(:search_retry_after, nil)
     |> assign(:suggestions, [])
     |> assign(:show_suggestions, false)
     |> assign(:command_mode, false)
     |> cancel_async(:paige_search)
     |> push_patch(to: ~p"/paige")}
  end

  def handle_event("set_lens", %{"lens" => lens}, socket) do
    lens = normalize_lens(lens)
    query = socket.assigns.query

    {:noreply,
     push_patch(socket,
       to:
         search_path(
           query,
           lens,
           1,
           socket.assigns.freshness,
           socket.assigns.safesearch
         )
     )}
  end

  def handle_event("set_filters", params, socket) do
    freshness = normalize_freshness(params["freshness"] || socket.assigns.freshness)
    safesearch = normalize_safesearch(params["safesearch"] || socket.assigns.safesearch)

    {:noreply,
     push_patch(socket,
       to:
         search_path(
           socket.assigns.query,
           socket.assigns.active_lens,
           1,
           freshness,
           safesearch
         )
     )}
  end

  def handle_event("retry_search", _params, socket) do
    if valid_search_query?(socket.assigns.query) do
      {:noreply, rerun_current_search(socket)}
    else
      {:noreply, socket}
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

  defp handle_search_submit(socket, query) do
    case allow_search_request(socket, :submit) do
      :ok ->
        if String.starts_with?(query, ">") do
          handle_command_submit(socket, query)
        else
          if String.length(query) < 2 do
            {:noreply,
             socket
             |> assign(:draft_query, query)
             |> assign(:show_suggestions, false)
             |> assign(:command_mode, false)
             |> put_flash(:error, "Enter at least two characters to search.")}
          else
            {:noreply,
             push_patch(socket,
               to:
                 search_path(
                   query,
                   socket.assigns.active_lens,
                   1,
                   socket.assigns.freshness,
                   socket.assigns.safesearch
                 )
             )}
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
          {:noreply, socket |> put_flash(:info, message) |> start_search(query)}
        end

      {:ok, %{mode: :operation, message: message}} ->
        {:noreply, socket |> put_flash(:info, message) |> start_search(query)}

      {:error, :unknown_action} ->
        {:noreply,
         push_patch(socket,
           to:
             search_path(
               query,
               socket.assigns.active_lens,
               1,
               socket.assigns.freshness,
               socket.assigns.safesearch
             )
         )}

      {:error, :insufficient_scope} ->
        {:noreply, put_flash(socket, :error, "This action is not allowed for this token scope.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Action could not be executed right now.")}
    end
  end

  defp start_search(socket, query, opts \\ []) do
    user = socket.assigns.current_user
    include_web? = Keyword.get(opts, :include_web?, true)
    lens = Keyword.get(opts, :lens, socket.assigns.active_lens) |> normalize_lens()
    page = Keyword.get(opts, :page, socket.assigns.page) |> normalize_page()
    freshness = Keyword.get(opts, :freshness, socket.assigns.freshness) |> normalize_freshness()

    safesearch =
      Keyword.get(opts, :safesearch, socket.assigns.safesearch) |> normalize_safesearch()

    web_search_allowed? = web_search_allowed?(user)
    domain_rules = socket.assigns.domain_rules
    rate_limit_identifier = socket.assigns.paige_rate_limit_identifier
    request_id = System.unique_integer([:positive, :monotonic])

    socket
    |> cancel_async(:paige_search)
    |> assign(:loading, true)
    |> assign(:query, query)
    |> assign(:draft_query, query)
    |> assign(:results, [])
    |> assign(:total_count, 0)
    |> assign(:searched?, false)
    |> assign(:search_request_id, request_id)
    |> assign(:search_status, :loading)
    |> assign(:search_error, nil)
    |> assign(:search_retry_after, nil)
    |> assign(:has_more?, false)
    |> assign(:failed_providers, [])
    |> assign(:successful_providers, [])
    |> assign(:provider_stats, [])
    |> assign(:command_mode, String.starts_with?(query, ">"))
    |> assign(:active_lens, lens)
    |> assign(:page, page)
    |> assign(:freshness, freshness)
    |> assign(:safesearch, safesearch)
    |> assign(:web_search_allowed?, web_search_allowed?)
    |> assign(:show_suggestions, false)
    |> start_async(:paige_search, fn ->
      external_search? =
        external_search_requested?(query, lens, include_web? and web_search_allowed?)

      results =
        case allow_external_search(external_search?, rate_limit_identifier) do
          :ok ->
            merged_search(user, query,
              limit: lens_limit(lens),
              include_web?: include_web? and web_search_allowed?,
              lens: lens,
              page: page,
              freshness: freshness,
              safesearch: safesearch,
              domain_rules: domain_rules
            )

          {:error, retry_after} ->
            rate_limited_search_result(retry_after)
        end

      {request_id, results}
    end)
  end

  @impl true
  def handle_async(:paige_search, {:ok, {request_id, search_results}}, socket) do
    if socket.assigns.search_request_id == request_id do
      {:noreply,
       socket
       |> assign(:results, search_results.results)
       |> assign(:total_count, search_results.total_count)
       |> assign(:web_degraded?, search_results.web_degraded?)
       |> assign(:web_available?, search_results.web_available?)
       |> assign(:has_more?, search_results.has_more?)
       |> assign(:failed_providers, search_results.failed_providers)
       |> assign(:successful_providers, search_results.successful_providers)
       |> assign(:provider_stats, search_results.provider_stats)
       |> assign(:search_status, search_results.status)
       |> assign(:search_error, search_results.error)
       |> assign(:search_retry_after, search_results.retry_after)
       |> assign(:search_request_id, nil)
       |> assign(:searched?, true)
       |> assign(:loading, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:paige_search, {:exit, reason}, socket) do
    if socket.assigns.loading and socket.assigns.search_request_id do
      {:noreply,
       socket
       |> assign(:loading, false)
       |> assign(:search_request_id, nil)
       |> assign(:searched?, true)
       |> assign(:search_status, :error)
       |> assign(:search_error, search_error_message(reason))
       |> assign(:search_retry_after, nil)
       |> assign(:web_degraded?, true)}
    else
      {:noreply, socket}
    end
  end

  defp assign_domain_rules(socket) do
    user = socket.assigns[:current_user]
    assign(socket, :domain_rules, DomainRules.rules_map(user && user.id))
  end

  defp rerun_current_search(socket) do
    if valid_search_query?(socket.assigns.query) do
      start_search(socket, socket.assigns.query,
        lens: socket.assigns.active_lens,
        page: socket.assigns.page,
        freshness: socket.assigns.freshness,
        safesearch: socket.assigns.safesearch
      )
    else
      socket
    end
  end

  defp reset_search(socket, query) do
    socket
    |> cancel_async(:paige_search)
    |> assign(:query, query)
    |> assign(:draft_query, query)
    |> assign(:results, [])
    |> assign(:total_count, 0)
    |> assign(:searched?, false)
    |> assign(:loading, false)
    |> assign(:search_request_id, nil)
    |> assign(:search_status, :idle)
    |> assign(:search_error, nil)
    |> assign(:search_retry_after, nil)
    |> assign(:has_more?, false)
    |> assign(:web_degraded?, false)
    |> assign(:failed_providers, [])
    |> assign(:successful_providers, [])
    |> assign(:provider_stats, [])
  end

  defp invalid_query(socket, query) do
    socket
    |> cancel_async(:paige_search)
    |> assign(:query, query)
    |> assign(:draft_query, query)
    |> assign(:results, [])
    |> assign(:total_count, 0)
    |> assign(:searched?, true)
    |> assign(:loading, false)
    |> assign(:search_request_id, nil)
    |> assign(:search_status, :invalid)
    |> assign(:search_error, "Keep search queries to #{@max_query_length} characters or fewer.")
    |> assign(:search_retry_after, nil)
    |> assign(:has_more?, false)
    |> assign(:web_degraded?, false)
    |> assign(:failed_providers, [])
    |> assign(:successful_providers, [])
    |> assign(:provider_stats, [])
    |> assign(:show_suggestions, false)
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

  defp valid_search_query?(query) when is_binary(query) do
    length = String.length(query)
    length >= 2 and length <= @max_query_length
  end

  defp valid_search_query?(_query), do: false

  defp query_too_long?(query) when is_binary(query),
    do: String.length(query) > @max_query_length

  defp query_too_long?(_query), do: false

  defp paige_rate_limit_identifier(%{assigns: %{current_user: %{id: id}}}),
    do: "user:#{id}"

  defp paige_rate_limit_identifier(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} ->
        headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
        "ip:#{ElektrineWeb.ClientIP.client_ip(address, headers)}"

      _peer_data ->
        "anonymous"
    end
  rescue
    _error -> "anonymous"
  end

  defp get_suggestions(%{assigns: %{current_user: nil}}, _query), do: []

  defp get_suggestions(socket, query),
    do: Search.get_suggestions(socket.assigns.current_user, query, 8)

  defp search_path(query, lens, page, freshness, safesearch) do
    params =
      []
      |> maybe_put_query_param(query)
      |> maybe_put_lens_param(lens)
      |> maybe_put_page_param(page)
      |> maybe_put_freshness_param(freshness)
      |> maybe_put_safesearch_param(safesearch)

    case URI.encode_query(params) do
      "" -> "/paige"
      query_string -> "/paige?" <> query_string
    end
  end

  defp maybe_put_query_param(params, query) when query in [nil, ""], do: params
  defp maybe_put_query_param(params, query), do: Keyword.put(params, :q, query)
  defp maybe_put_lens_param(params, lens) when lens in [nil, "", "all"], do: params
  defp maybe_put_lens_param(params, lens), do: Keyword.put(params, :lens, lens)
  defp maybe_put_page_param(params, page) when page in [nil, 1], do: params
  defp maybe_put_page_param(params, page), do: Keyword.put(params, :page, page)
  defp maybe_put_freshness_param(params, freshness) when freshness in [nil, "", "all"], do: params

  defp maybe_put_freshness_param(params, freshness),
    do: Keyword.put(params, :freshness, freshness)

  defp maybe_put_safesearch_param(params, safesearch)
       when safesearch in [nil, "", "moderate"],
       do: params

  defp maybe_put_safesearch_param(params, safesearch),
    do: Keyword.put(params, :safesearch, safesearch)

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
    page = Keyword.get(opts, :page, 1) |> normalize_page()
    freshness = Keyword.get(opts, :freshness, "all") |> normalize_freshness()
    safesearch = Keyword.get(opts, :safesearch, "moderate") |> normalize_safesearch()
    domain_rules = Keyword.get(opts, :domain_rules, %{})

    app_results = app_search(user, query, limit, lens, page)

    {web_results, web_meta} =
      external_search(query, limit, lens, include_web?,
        page: page,
        freshness: freshness_value(freshness),
        safesearch: safesearch
      )

    app_results = apply_lens_to_app_results(app_results.results, lens)
    web_results = DomainRules.apply_rules(web_results, domain_rules)

    combined_results =
      (app_results ++ web_results)
      |> Enum.uniq_by(&result_dedupe_key/1)
      |> Enum.sort_by(&(-Map.get(&1, :relevance, 0)))

    results =
      combined_results
      |> Enum.take(limit)

    status = search_status(results, web_meta, include_web?, lens)

    %{
      results: results,
      total_count: length(combined_results),
      web_degraded?: web_meta.degraded?,
      web_available?: web_meta.available?,
      has_more?: web_meta.has_more? and page < 10,
      failed_providers: web_meta.failed_providers,
      successful_providers: web_meta.successful_providers,
      provider_stats: web_meta.provider_stats,
      status: status,
      error: search_status_message(status, web_meta),
      retry_after: nil
    }
  end

  defp rate_limited_search_result(retry_after) do
    %{
      results: [],
      total_count: 0,
      web_degraded?: false,
      web_available?: true,
      has_more?: false,
      failed_providers: [],
      successful_providers: [],
      provider_stats: [],
      status: :rate_limited,
      error: "Too many web searches. Try again in #{retry_after} seconds.",
      retry_after: retry_after
    }
  end

  defp external_search_requested?(query, lens, include_web?) do
    include_web? and lens not in ["elektrine", "forums"] and String.length(query) >= 2 and
      not String.starts_with?(query, ">")
  end

  defp allow_external_search(false, _identifier), do: :ok
  defp allow_external_search(true, identifier), do: PaigeRateLimiter.allow_query(identifier)

  defp app_search(nil, _query, _limit, _lens, _page), do: %{results: [], total_count: 0}

  defp app_search(_user, _query, _limit, _lens, page) when page > 1,
    do: %{results: [], total_count: 0}

  defp app_search(_user, _query, _limit, lens, _page)
       when lens in ["web", "images", "videos", "news"],
       do: %{results: [], total_count: 0}

  defp app_search(user, query, limit, _lens, _page),
    do: Search.global_search(user, query, limit: limit)

  defp external_search(_query, _limit, _lens, false, _opts), do: {[], empty_web_meta()}

  defp external_search(_query, _limit, lens, true, _opts)
       when lens in ["elektrine", "forums"],
       do: {[], empty_web_meta()}

  defp external_search(query, limit, "images", true, opts),
    do: search_external(query, min(limit, 200), :images, opts)

  defp external_search(query, limit, "videos", true, opts),
    do: search_external(query, min(limit, 50), :videos, opts)

  defp external_search(query, limit, "news", true, opts),
    do: search_external(query, min(limit, 50), :news, opts)

  defp external_search(query, limit, "all", true, opts) do
    web_limit = max(limit - 8, 1)

    [
      {:web, min(web_limit, 20)},
      {:images, 12},
      {:videos, 12},
      {:news, 12}
    ]
    |> Task.async_stream(
      fn {kind, kind_limit} -> search_external(query, kind_limit, kind, opts) end,
      ordered: true,
      timeout: :infinity,
      max_concurrency: 4
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {[], failed_web_meta(reason)}
    end)
    |> combine_external()
  end

  defp external_search(query, limit, "web", true, opts),
    do: search_external(query, min(limit, 20), :web, opts)

  defp external_search(query, limit, _lens, true, opts),
    do: search_external(query, min(limit, 20), :web, opts)

  defp combine_external(parts) do
    metas = Enum.map(parts, &elem(&1, 1))

    available? = Enum.any?(metas, & &1.available?)

    meta = %{
      degraded?:
        Enum.any?(metas, & &1.degraded?) or
          (available? and Enum.any?(metas, &(not &1.available?))),
      available?: available?,
      has_more?: Enum.any?(metas, & &1.has_more?),
      failed_providers: metas |> Enum.flat_map(& &1.failed_providers) |> Enum.uniq(),
      successful_providers: metas |> Enum.flat_map(& &1.successful_providers) |> Enum.uniq(),
      provider_stats: Enum.flat_map(metas, &provider_stats_list(&1.provider_stats)),
      error: Enum.find_value(metas, & &1.error)
    }

    {Enum.flat_map(parts, &elem(&1, 0)), meta}
  end

  defp apply_lens_to_app_results(results, "elektrine"), do: results

  defp apply_lens_to_app_results(results, "forums"),
    do: Enum.filter(results, &(&1.type in ["discussion", "community", "federated"]))

  defp apply_lens_to_app_results(_results, lens)
       when lens in ["web", "images", "videos", "news"],
       do: []

  defp apply_lens_to_app_results(results, _lens), do: results

  defp result_dedupe_key(%{url: url}) when is_binary(url) do
    uri = URI.parse(url)

    normalized_uri = %{
      uri
      | fragment: nil,
        scheme: normalize_uri_part(uri.scheme),
        host: normalize_uri_part(uri.host)
    }

    URI.to_string(normalized_uri)
  rescue
    _error -> String.downcase(url)
  end

  defp result_dedupe_key(result), do: Map.get(result, :id) || :erlang.phash2(result)

  defp normalize_uri_part(value) when is_binary(value), do: String.downcase(value)
  defp normalize_uri_part(value), do: value

  defp search_external(query, limit, kind, opts) do
    query = String.trim(query || "")

    cond do
      String.length(query) < 2 ->
        {[], empty_web_meta()}

      String.starts_with?(query, ">") ->
        {[], empty_web_meta()}

      true ->
        case ElektrineWeb.WebSearch.search(
               query,
               kind: kind,
               limit: limit,
               page: Keyword.fetch!(opts, :page),
               freshness: Keyword.fetch!(opts, :freshness),
               safesearch: Keyword.fetch!(opts, :safesearch)
             ) do
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

            {safe_results, normalize_web_meta(meta)}

          {:error, {reason, meta}} when is_map(meta) ->
            meta = normalize_web_meta(meta)
            {[], %{meta | degraded?: true, error: reason}}

          {:error, reason} ->
            {[], failed_web_meta(reason)}
        end
    end
  rescue
    error -> {[], failed_web_meta(error)}
  end

  defp normalize_web_meta(meta) when is_map(meta) do
    %{
      degraded?: Map.get(meta, :degraded?, false),
      available?: Map.get(meta, :available?, true),
      has_more?: Map.get(meta, :has_more?, false),
      failed_providers: List.wrap(Map.get(meta, :failed_providers, [])),
      successful_providers: List.wrap(Map.get(meta, :successful_providers, [])),
      provider_stats: Map.get(meta, :provider_stats, []) || [],
      error: Map.get(meta, :error)
    }
  end

  defp normalize_web_meta(_meta), do: empty_web_meta()

  defp empty_web_meta do
    %{
      degraded?: false,
      available?: true,
      has_more?: false,
      failed_providers: [],
      successful_providers: [],
      provider_stats: [],
      error: nil
    }
  end

  defp failed_web_meta(reason) do
    %{
      degraded?: true,
      available?: not unconfigured_reason?(reason),
      has_more?: false,
      failed_providers: [],
      successful_providers: [],
      provider_stats: [],
      error: reason
    }
  end

  defp provider_stats_list(stats) when is_list(stats), do: stats
  defp provider_stats_list(stats) when is_map(stats), do: Map.to_list(stats)
  defp provider_stats_list(_stats), do: []

  defp search_status(results, web_meta, true, lens)
       when lens not in ["elektrine", "forums"] do
    cond do
      not web_meta.available? -> :unconfigured
      web_meta.error && results == [] -> :error
      web_meta.degraded? -> :partial
      results == [] -> :empty
      true -> :ok
    end
  end

  defp search_status([], _web_meta, _include_web?, _lens), do: :empty
  defp search_status(_results, _web_meta, _include_web?, _lens), do: :ok

  defp search_status_message(:unconfigured, _meta),
    do: "No web search sources are configured for Paige."

  defp search_status_message(:error, _meta),
    do: "Paige could not reach its search sources. Try again in a moment."

  defp search_status_message(_status, _meta), do: nil

  defp search_error_title(:rate_limited), do: "Search limit reached"
  defp search_error_title(:invalid), do: "Search query is too long"
  defp search_error_title(_status), do: "Search is temporarily unavailable"

  defp search_error_message(_reason),
    do: "Paige could not complete this search. Try again in a moment."

  defp unconfigured_reason?(reason),
    do: reason in [:unconfigured, :not_configured, :no_providers, :missing_provider]

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
          sources: result.metadata[:sources],
          image_url: Elektrine.MediaProxy.signed_url(result.metadata[:image_url]),
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

  defp normalize_page(page) when is_integer(page), do: page |> max(1) |> min(10)

  defp normalize_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {parsed, ""} -> normalize_page(parsed)
      _error -> 1
    end
  end

  defp normalize_page(_page), do: 1

  defp normalize_freshness(freshness) when is_binary(freshness) do
    freshness = String.downcase(String.trim(freshness))
    if freshness in ~w(all day week month year), do: freshness, else: "all"
  end

  defp normalize_freshness(_freshness), do: "all"

  defp freshness_value("day"), do: "pd"
  defp freshness_value("week"), do: "pw"
  defp freshness_value("month"), do: "pm"
  defp freshness_value("year"), do: "py"
  defp freshness_value(_freshness), do: nil

  defp normalize_safesearch(safesearch) when is_binary(safesearch) do
    safesearch = String.downcase(String.trim(safesearch))
    if safesearch in ~w(strict moderate off), do: safesearch, else: "moderate"
  end

  defp normalize_safesearch(_safesearch), do: "moderate"

  defp max_query_length, do: @max_query_length

  defp lens_ids,
    do: ["all", "elektrine", "web", "images", "videos", "news", "forums"]

  defp lens_limit("images"), do: 200
  defp lens_limit(lens) when lens in ["web", "videos", "news"], do: 50
  defp lens_limit(_lens), do: 50

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl px-3 pb-8 sm:px-5 lg:px-8">
      <.e_nav active_tab="paige" current_user={@current_user} badge_counts={@e_nav_badge_counts} />

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
                query={@draft_query}
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

              <.search_filters
                freshness={@freshness}
                safesearch={@safesearch}
                disabled={!@web_search_allowed?}
                class="mt-4"
              />

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
                <.button
                  variant="ghost"
                  size="sm"
                  class={quick_action_class()}
                  phx-click="search"
                  phx-value-query=">compose email"
                >
                  <.icon name="hero-pencil-square" class="h-4 w-4 text-primary" /> Compose Email
                </.button>
                <.button
                  variant="ghost"
                  size="sm"
                  class={quick_action_class()}
                  phx-click="search"
                  phx-value-query=">open chat"
                >
                  <.icon name="hero-chat-bubble-left-right" class="h-4 w-4 text-secondary" />
                  Open Chat
                </.button>
                <.button
                  variant="ghost"
                  size="sm"
                  class={quick_action_class()}
                  phx-click="search"
                  phx-value-query=">open notifications"
                >
                  <.icon name="hero-bell" class="h-4 w-4 text-warning" /> Notifications
                </.button>
                <.button
                  variant="ghost"
                  size="sm"
                  class={quick_action_class()}
                  phx-click="search"
                  phx-value-query="settings"
                >
                  <.icon name="hero-cog-6-tooth" class="h-4 w-4 text-info" /> Settings
                </.button>
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
                class="flex min-w-0 items-center justify-between gap-3 rounded-lg border border-base-300 px-3 py-2 text-sm"
              >
                <span class="truncate">{domain}</span>
                <span class="flex shrink-0 items-center gap-2">
                  <span class="badge badge-ghost badge-sm">{domain_rule_label(action)}</span>
                  <.button
                    type="button"
                    variant="ghost"
                    size="xs"
                    class="btn-square"
                    phx-click="remove_domain_rule"
                    phx-value-domain={domain}
                    aria-label={"Remove rule for #{domain}"}
                  >
                    <.icon name="hero-x-mark" class="h-4 w-4" />
                  </.button>
                </span>
              </li>
            </ul>
          </section>
        </div>
      <% else %>
        <% result_type_counts = result_type_counts(@results) %>
        <div class={[
          "grid gap-5",
          if(@web_search_allowed? and @domain_rules != %{},
            do: "lg:grid-cols-[minmax(0,1fr)_18rem]",
            else: "lg:grid-cols-1"
          )
        ]}>
          <div class="min-w-0 space-y-4">
            <section class="panel-card overflow-visible rounded-lg border border-base-300">
              <div class="border-b border-base-300 p-4 sm:p-5">
                <div class="mb-4 flex flex-wrap items-start justify-between gap-3">
                  <div class="min-w-0">
                    <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                      Paige
                    </p>
                    <h1 class="text-xl font-semibold leading-tight text-base-content sm:text-2xl">
                      Search results
                    </h1>
                    <p class="mt-1 break-words text-sm text-base-content/65">
                      Showing {active_lens_label(@active_lens, @web_search_allowed?)} matches for
                      <span class="font-semibold text-base-content">“{@query}”</span>
                    </p>
                  </div>

                  <div class="flex flex-wrap items-center gap-2">
                    <span class="badge badge-outline">
                      {@total_count} result{plural_suffix(@total_count)}
                    </span>
                    <span :if={@web_degraded?} class="badge badge-warning badge-outline gap-1">
                      <.icon name="hero-exclamation-triangle" class="h-3.5 w-3.5" /> Partial web
                    </span>
                  </div>
                </div>

                <.search_form
                  query={@draft_query}
                  command_mode={@command_mode}
                  suggestions={@suggestions}
                  show_suggestions={@show_suggestions}
                />
              </div>

              <div class="space-y-4 p-4 sm:p-5">
                <.pill_switcher
                  event="set_lens"
                  param="lens"
                  active={@active_lens}
                  options={lenses(@web_search_allowed?)}
                />

                <.search_filters
                  freshness={@freshness}
                  safesearch={@safesearch}
                  disabled={!@web_search_allowed?}
                />

                <.trust_wall_notice
                  :if={web_search_locked?(@active_lens, @web_search_allowed?)}
                  min_trust_level={@web_search_min_trust_level}
                />

                <%= if result_type_counts != [] do %>
                  <div class="flex flex-wrap gap-2">
                    <span
                      :for={{type, count} <- result_type_counts}
                      class="inline-flex items-center gap-1.5 rounded-full border border-base-300 bg-base-100 px-3 py-1 text-xs text-base-content/70"
                    >
                      <.icon name={result_icon(type)} class="h-3.5 w-3.5 opacity-70" />
                      <span>{format_result_type(type)}</span>
                      <span class="font-semibold text-base-content">{count}</span>
                    </span>
                  </div>
                <% end %>
              </div>
            </section>

            <.results_skeleton :if={@loading} />

            <div
              :if={not @loading and @search_status == :unconfigured}
              role="alert"
              class="panel-card rounded-lg border border-warning/35 bg-warning/10 p-4 sm:p-5"
            >
              <div class="flex items-start gap-3">
                <.icon name="hero-wrench-screwdriver" class="mt-0.5 h-5 w-5 shrink-0 text-warning" />
                <div class="min-w-0 flex-1">
                  <h2 class="font-semibold text-base-content">Web search is not configured</h2>
                  <p class="mt-1 text-sm text-base-content/70">{@search_error}</p>
                  <.button
                    type="button"
                    variant="ghost"
                    size="sm"
                    class="mt-3 rounded-full"
                    phx-click="retry_search"
                  >
                    <.icon name="hero-arrow-path" class="h-4 w-4" /> Check again
                  </.button>
                </div>
              </div>
            </div>

            <div
              :if={not @loading and @search_status in [:error, :rate_limited, :invalid]}
              role="alert"
              class="panel-card rounded-lg border border-error/35 bg-error/10 p-4 sm:p-5"
            >
              <div class="flex items-start gap-3">
                <.icon name="hero-exclamation-circle" class="mt-0.5 h-5 w-5 shrink-0 text-error" />
                <div class="min-w-0 flex-1">
                  <h2 class="font-semibold text-base-content">
                    {search_error_title(@search_status)}
                  </h2>
                  <p class="mt-1 text-sm text-base-content/70">{@search_error}</p>
                  <.button
                    :if={@search_status != :invalid}
                    type="button"
                    variant="ghost"
                    size="sm"
                    class="mt-3 rounded-full"
                    phx-click="retry_search"
                  >
                    <.icon name="hero-arrow-path" class="h-4 w-4" />
                    {if @search_status == :rate_limited, do: "Try again", else: "Retry search"}
                  </.button>
                </div>
              </div>
            </div>

            <%= if not @loading and @searched? do %>
              <%= if @results != [] do %>
                <div class="w-full space-y-3">
                  <div
                    :if={@search_status == :partial}
                    role="status"
                    class="flex items-start gap-2 rounded-lg border border-warning/30 bg-warning/10 px-3 py-2 text-sm text-warning"
                  >
                    <.icon name="hero-exclamation-triangle" class="mt-0.5 h-4 w-4 shrink-0" />
                    <span class="min-w-0 flex-1">
                      Some web sources were unavailable{failed_provider_summary(@failed_providers)}.
                    </span>
                    <.button
                      type="button"
                      variant="ghost"
                      size="xs"
                      class="shrink-0"
                      phx-click="retry_search"
                    >
                      Retry
                    </.button>
                  </div>

                  <.lens_results
                    results={@results}
                    active_lens={@active_lens}
                    domain_rules={@domain_rules}
                    can_rank_domains?={@current_user != nil and @web_search_allowed?}
                  />
                </div>
              <% else %>
                <%= if @search_status not in [:error, :unconfigured, :rate_limited, :invalid] do %>
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
                        <.button
                          variant="default"
                          size="sm"
                          class="rounded-full"
                          phx-click="clear_search"
                        >
                          <.icon name="hero-arrow-uturn-left" class="h-4 w-4" /> Start over
                        </.button>
                        <.button
                          :if={
                            @web_search_allowed? and
                              @active_lens not in ["web", "images", "videos", "news"]
                          }
                          size="sm"
                          class="rounded-full"
                          phx-click="set_lens"
                          phx-value-lens="web"
                        >
                          <.icon name="hero-globe-alt" class="h-4 w-4" /> Search the web
                        </.button>
                      </div>
                    </div>
                  </div>
                <% end %>
              <% end %>

              <.pagination
                :if={
                  @search_status not in [:error, :unconfigured, :rate_limited, :invalid] and
                    (@page > 1 or @has_more?)
                }
                query={@query}
                lens={@active_lens}
                page={@page}
                freshness={@freshness}
                safesearch={@safesearch}
                has_more?={@has_more?}
              />
            <% end %>
          </div>

          <aside
            :if={@web_search_allowed? and @domain_rules != %{}}
            class="space-y-3 lg:sticky lg:top-20 lg:self-start"
          >
            <section class="panel-card rounded-lg border border-base-300 p-3">
              <div class="mb-2 flex items-center justify-between">
                <h2 class="text-sm font-semibold">Domain rules</h2>
                <span class="badge badge-ghost badge-sm">{map_size(@domain_rules)}</span>
              </div>
              <ul class="space-y-1">
                <li
                  :for={{domain, action} <- Enum.sort(@domain_rules)}
                  class="flex items-center justify-between gap-2 rounded-lg px-2 py-1.5 text-sm hover:bg-base-200/50"
                >
                  <span class="min-w-0 truncate">{domain}</span>
                  <.button
                    type="button"
                    variant="ghost"
                    size="xs"
                    phx-click="remove_domain_rule"
                    phx-value-domain={domain}
                  >
                    {domain_rule_label(action)}
                  </.button>
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
      <form
        phx-submit="search"
        phx-change="suggest"
        role="search"
        aria-label="Search with Paige"
        class="w-full"
      >
        <div class="join flex w-full">
          <label for="global-search-input" class="sr-only">Search with Paige</label>
          <div class="input input-bordered join-item flex min-w-0 flex-1 items-center gap-2 rounded-l-full rounded-r-none">
            <.icon
              name={if @command_mode, do: "hero-command-line", else: "hero-magnifying-glass"}
              class={"h-4 w-4 shrink-0 " <> if(@command_mode, do: "text-primary", else: "opacity-60")}
            />
            <input
              id="global-search-input"
              type="search"
              name="query"
              value={@query}
              placeholder="Paige..."
              role="combobox"
              aria-autocomplete="list"
              aria-haspopup="listbox"
              aria-expanded={@show_suggestions and @suggestions != []}
              aria-controls="paige-search-suggestions"
              aria-keyshortcuts="/ Control+K Meta+K"
              class="min-w-0 grow bg-transparent text-base sm:text-sm"
              autocomplete="off"
              autocapitalize="off"
              enterkeyhint="search"
              minlength="2"
              maxlength={max_query_length()}
              phx-debounce="300"
              autofocus={@hero}
            />

            <span
              :if={@command_mode}
              class="badge badge-primary badge-sm hidden shrink-0 sm:inline-flex"
            >
              Command
            </span>
            <.button
              type="button"
              variant="ghost"
              size="xs"
              phx-click="clear_search"
              data-search-clear="true"
              aria-label="Clear search"
              class={if(@query == "", do: "pointer-events-none invisible", else: nil)}
            >
              <.icon name="hero-x-mark" class="h-4 w-4" />
            </.button>
          </div>

          <.button
            type="submit"
            class="join-item rounded-l-none rounded-r-full px-4"
            aria-label="Search"
            title="Search"
          >
            <.icon name="hero-magnifying-glass" class="h-4 w-4" />
          </.button>
        </div>
      </form>

      <div
        id="paige-search-suggestions"
        role="listbox"
        aria-label="Search suggestions"
        hidden={not @show_suggestions or @suggestions == []}
        class="dropdown-content absolute left-0 right-0 z-30 mt-2 overflow-hidden rounded-lg text-left"
      >
        <button
          :for={{suggestion, index} <- Enum.with_index(@suggestions)}
          id={"paige-search-suggestion-#{index}"}
          type="button"
          role="option"
          aria-selected="false"
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

      <p class="sr-only" role="status" aria-live="polite">
        <%= if @show_suggestions and @suggestions != [] do %>
          {length(@suggestions)} suggestion{plural_suffix(length(@suggestions))} available.
        <% end %>
      </p>
    </div>
    """
  end

  attr :freshness, :string, required: true
  attr :safesearch, :string, required: true
  attr :disabled, :boolean, default: false
  attr :class, :string, default: nil

  defp search_filters(assigns) do
    ~H"""
    <form
      id="paige-search-filters"
      phx-change="set_filters"
      aria-label="Search filters"
      class={["flex flex-wrap items-end gap-3", @class]}
    >
      <label class="form-control min-w-32">
        <span class="label py-1 text-xs font-medium text-base-content/70">Date</span>
        <select
          name="freshness"
          class="select select-bordered select-sm min-h-11 rounded-full"
          disabled={@disabled}
        >
          <option value="all" selected={@freshness == "all"}>Any time</option>
          <option value="day" selected={@freshness == "day"}>Past day</option>
          <option value="week" selected={@freshness == "week"}>Past week</option>
          <option value="month" selected={@freshness == "month"}>Past month</option>
          <option value="year" selected={@freshness == "year"}>Past year</option>
        </select>
      </label>

      <label class="form-control min-w-36">
        <span class="label py-1 text-xs font-medium text-base-content/70">Safe Search</span>
        <select
          name="safesearch"
          class="select select-bordered select-sm min-h-11 rounded-full"
          disabled={@disabled}
        >
          <option value="strict" selected={@safesearch == "strict"}>Strict</option>
          <option value="moderate" selected={@safesearch == "moderate"}>Moderate</option>
          <option value="off" selected={@safesearch == "off"}>Off</option>
        </select>
      </label>
    </form>
    """
  end

  attr :query, :string, required: true
  attr :lens, :string, required: true
  attr :page, :integer, required: true
  attr :freshness, :string, required: true
  attr :safesearch, :string, required: true
  attr :has_more?, :boolean, required: true

  defp pagination(assigns) do
    ~H"""
    <nav aria-label="Search result pages" class="flex items-center justify-between gap-3 pt-2">
      <.button
        :if={@page > 1}
        patch={search_path(@query, @lens, @page - 1, @freshness, @safesearch)}
        variant="ghost"
        class="min-h-11 rounded-full"
        rel="prev"
      >
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Previous
      </.button>
      <span :if={@page == 1} aria-hidden="true"></span>

      <span class="text-sm font-medium text-base-content/70">Page {@page}</span>

      <.button
        :if={@has_more? and @page < 10}
        patch={search_path(@query, @lens, @page + 1, @freshness, @safesearch)}
        variant="ghost"
        class="min-h-11 rounded-full"
        rel="next"
      >
        Next <.icon name="hero-arrow-right" class="h-4 w-4" />
      </.button>
      <span :if={not @has_more? or @page >= 10} aria-hidden="true"></span>
    </nav>
    """
  end

  attr :min_trust_level, :any, required: true
  attr :class, :string, default: nil

  defp trust_wall_notice(assigns) do
    ~H"""
    <div class={[
      "rounded-box border border-warning/30 bg-warning/10 p-4 text-left text-sm text-base-content/75",
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
            <div class="skeleton h-8 w-8 shrink-0 rounded-lg"></div>
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
    "justify-start gap-2 rounded-lg px-3"
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

  defp active_lens_label(lens, web_search_allowed?) do
    lenses(web_search_allowed?)
    |> Enum.find(%{label: "All"}, &(&1.value == lens))
    |> Map.fetch!(:label)
    |> String.downcase()
  end

  defp result_type_counts(results) do
    results
    |> Enum.frequencies_by(&Map.get(&1, :type, "other"))
    |> Enum.sort_by(fn {type, count} -> {-count, format_result_type(type)} end)
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
                  referrerpolicy="no-referrer"
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
                  referrerpolicy="no-referrer"
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
                <div class="surface-subtle aspect-video overflow-hidden rounded-lg">
                  <%= if image_url = result_image_url(result) do %>
                    <img
                      src={image_url}
                      alt=""
                      class="h-full w-full object-cover transition group-hover:scale-[1.02]"
                      loading="lazy"
                      referrerpolicy="no-referrer"
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

  defp failed_provider_summary([]), do: ""

  defp failed_provider_summary(providers) do
    labels =
      providers
      |> Enum.map(&provider_label/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if labels == [], do: "", else: ": " <> Enum.join(labels, ", ")
  end

  defp provider_label({provider, _reason}), do: provider_label(provider)

  defp provider_label(provider) when is_atom(provider) do
    provider
    |> Module.split()
    |> List.last()
    |> to_string()
  end

  defp provider_label(provider) when is_binary(provider), do: plain_text(provider)
  defp provider_label(_provider), do: ""

  attr :result, :map, required: true

  defp search_result_content(assigns) do
    ~H"""
    <article class="flex min-w-0 gap-3">
      <div class="surface-subtle mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center overflow-hidden rounded-lg text-base-content/60">
        <.icon name={result_icon(@result.type)} class="h-4 w-4" />
      </div>

      <div class="min-w-0 flex-1 space-y-1">
        <div class="flex min-w-0 items-center gap-2 text-xs text-base-content/55">
          <span class="shrink-0 font-semibold text-base-content/75">
            {plain_text(result_source_label(@result))}
          </span>
          <span :if={provider_source_label(@result)} class="shrink-0 text-base-content/65">
            via {provider_source_label(@result)}
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
          class="hidden h-20 w-28 shrink-0 rounded-lg object-cover sm:block"
          loading="lazy"
          referrerpolicy="no-referrer"
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

  defp provider_source_label(%{type: type} = result)
       when type in ["web", "image", "video", "news"] do
    sources =
      result
      |> Map.get(:sources, [])
      |> List.wrap()
      |> Kernel.++(List.wrap(Map.get(result, :source)))
      |> Enum.map(&plain_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq_by(&String.downcase/1)

    case sources do
      [] -> nil
      sources -> compact_source_labels(sources)
    end
  end

  defp provider_source_label(_result), do: nil

  defp compact_source_labels(sources) do
    visible = Enum.take(sources, 3)
    remaining = length(sources) - length(visible)
    label = Enum.join(visible, " + ")
    if remaining > 0, do: label <> " +#{remaining}", else: label
  end

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

  defp result_image_url(%{image_url: image_url}) when is_binary(image_url) and image_url != "",
    do: image_url

  defp result_image_url(_result), do: nil

  defp safe_optional_url(nil), do: nil

  defp safe_optional_url(url) do
    case SafeExternalURL.normalize_href(url) do
      {:ok, safe_url} -> safe_url
      {:error, _reason} -> nil
    end
  end
end
