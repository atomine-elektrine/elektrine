defmodule ElektrineWeb.PortalLive.Reader do
  @moduledoc false

  use ElektrineWeb, :live_component

  alias Elektrine.RSS
  alias Elektrine.Security.SafeExternalURL

  @reader_limit 18

  @impl true
  def update(assigns, socket) do
    socket =
      assign(
        socket,
        Map.take(assigns, [:current_user, :timezone, :time_format, :filter, :attention_filter])
      )

    reader_params = Map.get(assigns, :reader_params, %{})
    user_id = assigns.current_user.id

    socket =
      if load_reader_data?(socket, user_id) do
        socket
        |> assign(:reader_user_id, user_id)
        |> assign(:rss_subscriptions, RSS.list_subscriptions(user_id))
        |> assign_new(:rss_query, fn -> "" end)
        |> assign(:rss_items, load_rss_items(user_id))
      else
        socket
      end

    if socket.assigns[:reader_user_id] == user_id do
      rss_subscriptions = socket.assigns[:rss_subscriptions] || []

      rss_source_filter =
        normalize_rss_source(
          reader_params["rss_source"] || socket.assigns[:rss_source_filter],
          rss_subscriptions
        )

      socket =
        socket
        |> assign(:reader_params, reader_params)
        |> assign(:rss_source_filter, rss_source_filter)
        |> assign(:rss_list_density, normalize_rss_list_density(reader_params["rss_density"]))
        |> maybe_include_requested_rss_item(reader_params["rss_item"])

      reader_items = filtered_rss_items(socket.assigns)

      {:ok,
       assign(
         socket,
         :selected_rss_item_id,
         selected_rss_item_id_from_param(
           reader_params["rss_item"],
           reader_items,
           socket.assigns[:selected_rss_item_id]
         )
       )}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card panel-card self-start overflow-hidden">
      <div class="card-body p-3 sm:p-4">
        <% reader_items = filtered_rss_items(assigns) %>
        <% selected_item = selected_rss_item(reader_items, @selected_rss_item_id) %>

        <div class="mb-3 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
          <div class="min-w-0">
            <h1 class="truncate text-lg font-semibold tracking-tight sm:text-2xl">Feed Reader</h1>
          </div>

          <div class="flex gap-2 sm:justify-end">
            <.link navigate={~p"/settings/rss"} class="btn btn-sm btn-secondary max-sm:flex-1">
              Add feed
            </.link>
          </div>
        </div>

        <%= if Enum.empty?(@rss_items) do %>
          <div class="rounded-lg border border-dashed border-base-300 p-5 text-center">
            <h2 class="text-lg font-semibold">No feed items yet</h2>
            <p class="mx-auto mt-2 max-w-md text-sm text-base-content/65">
              Add RSS feeds from settings. New items will appear here first.
            </p>
            <.link navigate={~p"/settings/rss"} class="btn btn-sm btn-secondary mt-4">
              Manage feeds
            </.link>
          </div>
        <% else %>
          <% compact_reader? = @rss_list_density == "compact" %>

          <div class="flex min-w-0 flex-col gap-3">
            <aside>
              <div>
                <div class="mb-2">
                  <p class="text-xs uppercase tracking-[0.16em] text-base-content/50">
                    Sources
                  </p>
                  <div class="-mx-1 mt-2 flex gap-2 overflow-x-auto px-1 pb-2 sm:mx-0 sm:flex-wrap sm:overflow-visible sm:px-0 sm:pb-1">
                    <.link
                      patch={portal_patch(assigns, rss_source: "all", rss_item: nil)}
                      class={rss_source_button_class(@rss_source_filter, "all")}
                    >
                      All feeds <span class="opacity-60">{length(@rss_items)}</span>
                    </.link>

                    <%= for subscription <- @rss_subscriptions do %>
                      <% source_id = Integer.to_string(subscription.feed_id) %>
                      <% source_count = Enum.count(@rss_items, &(&1.feed_id == subscription.feed_id)) %>
                      <.link
                        patch={portal_patch(assigns, rss_source: source_id, rss_item: nil)}
                        class={rss_source_button_class(@rss_source_filter, source_id)}
                      >
                        <span class="truncate">{rss_subscription_title(subscription)}</span>
                        <span class="opacity-60">{source_count}</span>
                      </.link>
                    <% end %>
                  </div>
                </div>
              </div>
            </aside>

            <div class="grid min-w-0 gap-3 lg:grid-cols-[minmax(0,0.88fr)_minmax(0,1.12fr)]">
              <section class="order-2 space-y-2 lg:order-1 lg:flex lg:h-[34rem] lg:flex-col">
                <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between sm:gap-3">
                  <h2 class="text-base font-semibold">Latest items</h2>
                  <div class="join w-full sm:w-auto">
                    <.link
                      patch={portal_patch(assigns, rss_density: "comfortable")}
                      class={[
                        rss_density_button_class(@rss_list_density, "comfortable"),
                        "join-item flex-1 sm:flex-none"
                      ]}
                    >
                      Cards
                    </.link>
                    <.link
                      patch={portal_patch(assigns, rss_density: "compact")}
                      class={[
                        rss_density_button_class(@rss_list_density, "compact"),
                        "join-item flex-1 sm:flex-none"
                      ]}
                    >
                      Compact
                    </.link>
                  </div>
                </div>

                <div
                  class="space-y-2 lg:min-h-0 lg:flex-1 lg:overflow-y-auto lg:pr-1"
                  data-role="rss-reader-list"
                >
                  <%= if Enum.empty?(reader_items) do %>
                    <div class="rounded-lg border border-dashed border-base-300 p-4 text-center text-sm text-base-content/65">
                      No feed items match this view.
                    </div>
                  <% else %>
                    <%= for item <- reader_items do %>
                      <.link
                        patch={portal_patch(assigns, rss_item: item.id)}
                        class={[
                          rss_item_button_class(
                            item,
                            (selected_item && selected_item.id) || @selected_rss_item_id,
                            @rss_list_density
                          ),
                          "relative block cursor-pointer overflow-hidden"
                        ]}
                      >
                        <div
                          :if={!compact_reader? && rss_item_background_style(item)}
                          class="pointer-events-none absolute inset-0 bg-cover bg-center opacity-10"
                          style={rss_item_background_style(item)}
                        >
                        </div>

                        <div class="relative block w-full text-left">
                          <div class="mb-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/55">
                            <span class="font-medium text-base-content/70">
                              {rss_item_feed_title(item)}
                            </span>
                            <span :if={rss_item_author(item)}>by {rss_item_author(item)}</span>
                          </div>

                          <h2 class={[
                            "text-sm font-semibold leading-snug sm:text-base",
                            if(compact_reader?, do: "line-clamp-1", else: "line-clamp-2")
                          ]}>
                            {rss_item_title(item)}
                          </h2>

                          <p
                            :if={!compact_reader? && rss_item_excerpt(item)}
                            class="mt-1 line-clamp-2 text-sm leading-6 text-base-content/65"
                          >
                            {rss_item_excerpt(item)}
                          </p>

                          <div class={[
                            "flex flex-wrap items-center gap-2 text-xs text-base-content/50",
                            if(compact_reader?, do: "mt-1", else: "mt-2")
                          ]}>
                            <%= if item.published_at do %>
                              <.local_time
                                datetime={item.published_at}
                                format="relative"
                                timezone={@timezone}
                                time_format={@time_format}
                              />
                            <% end %>
                            <span>{rss_item_reading_minutes(item)} min read</span>
                          </div>
                        </div>
                      </.link>
                    <% end %>
                  <% end %>
                </div>
              </section>

              <section class="order-1 rounded-2xl border border-base-300 bg-base-100/80 p-3 sm:p-4 lg:sticky lg:top-24 lg:order-2 lg:h-[34rem] lg:overflow-y-auto">
                <%= if selected_item do %>
                  <div
                    :if={rss_item_image(selected_item)}
                    class="mb-4 aspect-[16/7] overflow-hidden rounded-xl bg-base-200"
                  >
                    <img
                      src={rss_item_image(selected_item)}
                      alt=""
                      class="h-full w-full object-cover"
                    />
                  </div>

                  <div class="mb-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/55">
                    <span class="font-medium text-base-content/70">
                      {rss_item_feed_title(selected_item)}
                    </span>
                    <span :if={rss_item_author(selected_item)}>
                      by {rss_item_author(selected_item)}
                    </span>
                    <%= if selected_item.published_at do %>
                      <.local_time
                        datetime={selected_item.published_at}
                        format="relative"
                        timezone={@timezone}
                        time_format={@time_format}
                      />
                    <% end %>
                    <span>{rss_item_reading_minutes(selected_item)} min read</span>
                  </div>

                  <h2 class="break-words text-lg font-semibold leading-tight sm:text-2xl">
                    {rss_item_title(selected_item)}
                  </h2>

                  <div
                    :if={rss_item_categories(selected_item) != []}
                    class="mt-3 flex flex-wrap gap-1"
                  >
                    <%= for category <- Enum.take(rss_item_categories(selected_item), 8) do %>
                      <span class="badge badge-outline badge-sm">{category}</span>
                    <% end %>
                  </div>

                  <div
                    :if={rss_item_body_html(selected_item)}
                    class="mt-4 max-w-none break-words text-sm leading-7 text-base-content/80 [&_a]:text-primary [&_a]:underline [&_blockquote]:border-l-4 [&_blockquote]:border-base-300 [&_blockquote]:pl-4 [&_blockquote]:italic [&_h1]:text-xl [&_h1]:font-semibold [&_h2]:text-lg [&_h2]:font-semibold [&_h3]:font-semibold [&_img]:my-4 [&_img]:max-w-full [&_img]:rounded-xl [&_li]:ml-5 [&_li]:list-disc [&_ol_li]:list-decimal [&_p]:mb-3 [&_pre]:max-w-full [&_pre]:overflow-x-auto"
                  >
                    {raw(rss_item_body_html(selected_item))}
                  </div>

                  <div class="mt-4 flex flex-wrap gap-2">
                    <a
                      href={rss_item_href(selected_item)}
                      target="_blank"
                      rel="noopener"
                      class="btn btn-sm btn-secondary"
                    >
                      Read original
                    </a>
                    <.link navigate={~p"/settings/rss"} class="btn btn-sm btn-ghost">
                      Manage feeds
                    </.link>
                  </div>
                <% else %>
                  <div class="flex min-h-48 items-center justify-center rounded-xl border border-dashed border-base-300 p-6 text-center text-sm text-base-content/65">
                    Select a feed item to preview it here.
                  </div>
                <% end %>
              </section>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp load_reader_data?(socket, user_id) do
    socket.assigns[:reader_user_id] != user_id or
      not Map.has_key?(socket.assigns, :rss_items) or
      not Map.has_key?(socket.assigns, :rss_subscriptions)
  end

  defp load_rss_items(user_id) do
    RSS.get_timeline_items(user_id, limit: @reader_limit)
  end

  defp maybe_include_requested_rss_item(socket, item_id) do
    parsed_id = parse_rss_item_id(item_id)

    cond do
      is_nil(parsed_id) ->
        socket

      Enum.any?(socket.assigns[:rss_items] || [], &(&1.id == parsed_id)) ->
        socket

      true ->
        case RSS.get_timeline_item(socket.assigns.current_user.id, parsed_id) do
          nil ->
            socket

          item ->
            update(socket, :rss_items, fn items ->
              [item | List.wrap(items)]
              |> Enum.uniq_by(& &1.id)
            end)
        end
    end
  end

  defp filtered_rss_items(assigns) do
    source = assigns[:rss_source_filter] || "all"
    query = String.downcase(assigns[:rss_query] || "")

    assigns[:rss_items]
    |> List.wrap()
    |> Enum.filter(&(rss_source_matches?(&1, source) and rss_query_matches?(&1, query)))
  end

  defp selected_rss_item(items, selected_item_id) do
    Enum.find(items, &(&1.id == selected_item_id)) || List.first(items)
  end

  defp selected_rss_item_id([%{id: id} | _]), do: id
  defp selected_rss_item_id(_items), do: nil

  defp selected_rss_item_id_from_param(item_id, items, current_id) do
    parsed_id = parse_rss_item_id(item_id)

    cond do
      Enum.any?(items, &(&1.id == parsed_id)) -> parsed_id
      Enum.any?(items, &(&1.id == current_id)) -> current_id
      true -> selected_rss_item_id(items)
    end
  end

  defp portal_patch(assigns, overrides) do
    params =
      [
        view: "reader",
        filter: assigns[:filter] || "all",
        attention: assigns[:attention_filter] || "all",
        rss_source: assigns[:rss_source_filter] || "all",
        rss_density: assigns[:rss_list_density] || "comfortable",
        rss_item: assigns[:selected_rss_item_id]
      ]
      |> Keyword.merge(overrides)
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)

    ~p"/portal?#{params}"
  end

  defp normalize_rss_source("all", _subscriptions), do: "all"

  defp normalize_rss_source(source, subscriptions) do
    source = to_string(source || "all")

    if Enum.any?(subscriptions, &(Integer.to_string(&1.feed_id) == source)) do
      source
    else
      "all"
    end
  end

  defp normalize_rss_list_density("compact"), do: "compact"
  defp normalize_rss_list_density(_density), do: "comfortable"

  defp rss_source_matches?(_item, "all"), do: true

  defp rss_source_matches?(%{feed_id: feed_id}, source) do
    Integer.to_string(feed_id) == source
  end

  defp rss_query_matches?(_item, ""), do: true

  defp rss_query_matches?(item, query) do
    item
    |> rss_search_text()
    |> String.contains?(query)
  end

  defp rss_search_text(item) do
    [
      rss_item_title(item),
      rss_item_excerpt(item),
      rss_item_feed_title(item),
      Map.get(item, :author),
      item |> rss_item_categories() |> Enum.join(" ")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp rss_item_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp rss_item_title(_item), do: "Untitled item"

  defp rss_item_excerpt(item) do
    item
    |> rss_item_summary_source()
    |> case do
      nil -> nil
      text -> text |> strip_markup() |> truncate_text(220)
    end
  end

  defp rss_item_body(item) do
    item
    |> rss_item_body_source()
    |> case do
      nil -> nil
      text -> strip_markup(text)
    end
  end

  defp rss_item_body_html(item) do
    item
    |> rss_item_body_source()
    |> case do
      nil ->
        nil

      text ->
        text
        |> decode_html_entities()
        |> ElektrineWeb.HtmlHelpers.safe_basic_html()
        |> remove_duplicate_rss_hero_image(item)
    end
  end

  defp rss_item_summary_source(item) do
    [Map.get(item, :summary), Map.get(item, :content)]
    |> Enum.find_value(&Elektrine.Strings.present/1)
  end

  defp rss_item_body_source(item) do
    [Map.get(item, :content), Map.get(item, :summary)]
    |> Enum.find_value(&Elektrine.Strings.present/1)
  end

  defp rss_item_feed_title(%{feed_title: title}) when is_binary(title) and title != "", do: title

  defp rss_item_feed_title(%{feed_url: url}) when is_binary(url) and url != "",
    do: URI.parse(url).host || url

  defp rss_item_feed_title(_item), do: "Feed"

  defp rss_item_href(%{url: url}), do: safe_external_href(url)
  defp rss_item_href(_item), do: "#"

  defp rss_item_image(item) do
    [
      Map.get(item, :image_url),
      image_enclosure_url(Map.get(item, :enclosure_url), Map.get(item, :enclosure_type)),
      html_image_url(Map.get(item, :content), item),
      html_image_url(Map.get(item, :summary), item),
      Map.get(item, :feed_image_url),
      Map.get(item, :feed_favicon_url)
    ]
    |> Enum.find_value(&safe_image_href/1)
  end

  defp rss_item_background_style(item) do
    case rss_item_image(item) do
      nil ->
        nil

      "#" ->
        nil

      url ->
        "background-image: linear-gradient(180deg, rgba(0,0,0,0.04), rgba(0,0,0,0.34)), url(\"#{css_string_escape(url)}\")"
    end
  end

  defp css_string_escape(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp remove_duplicate_rss_hero_image(html, item) when is_binary(html) do
    hero_image = rss_item_image(item)

    if Elektrine.Strings.present?(hero_image) do
      Regex.replace(~r/<img\b[^>]*\bsrc=["']([^"']+)["'][^>]*>/i, html, fn image_tag, src ->
        if duplicate_rss_image?(src, hero_image, item), do: "", else: image_tag
      end)
    else
      html
    end
  end

  defp remove_duplicate_rss_hero_image(html, _item), do: html

  defp duplicate_rss_image?(src, hero_image, item) do
    body_image =
      src
      |> normalize_rss_image_url()
      |> absolute_rss_url(Map.get(item, :url) || Map.get(item, :feed_url))
      |> safe_image_href()
      |> normalize_rss_image_url()

    hero_image = normalize_rss_image_url(hero_image)

    body_image == hero_image
  end

  defp normalize_rss_image_url(url) when is_binary(url) do
    url
    |> decode_html_entities()
    |> String.replace(~r/&(amp;|#0*38;|#x0*26;)/i, "&")
  end

  defp normalize_rss_image_url(url), do: url

  defp image_enclosure_url(url, type) when is_binary(url) and is_binary(type) do
    if String.starts_with?(String.downcase(type), "image/"), do: url
  end

  defp image_enclosure_url(_url, _type), do: nil

  defp html_image_url(html, item) when is_binary(html) do
    case Regex.run(~r/<img\b[^>]*\bsrc=["']([^"']+)["']/i, html) do
      [_, url] -> absolute_rss_url(url, Map.get(item, :url) || Map.get(item, :feed_url))
      _ -> nil
    end
  end

  defp html_image_url(_html, _item), do: nil

  defp absolute_rss_url(url, base_url) when is_binary(url) do
    url = String.trim(url)

    cond do
      url == "" -> nil
      String.starts_with?(url, "//") -> "https:#{url}"
      URI.parse(url).scheme in ["http", "https"] -> url
      is_binary(base_url) -> URI.merge(base_url, url) |> URI.to_string()
      true -> nil
    end
  end

  defp absolute_rss_url(_url, _base_url), do: nil

  defp safe_image_href(url) when is_binary(url) do
    case safe_external_href(url) do
      "#" -> nil
      safe_url -> safe_url
    end
  end

  defp safe_image_href(_url), do: nil

  defp rss_item_author(%{author: author}) when is_binary(author) and author != "", do: author
  defp rss_item_author(_item), do: nil

  defp rss_item_categories(%{categories: categories}) when is_list(categories) do
    categories
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp rss_item_categories(_item), do: []

  defp rss_item_reading_minutes(item) do
    item
    |> rss_item_body()
    |> case do
      nil -> rss_item_title(item)
      "" -> rss_item_title(item)
      text -> text
    end
    |> reading_minutes_for_text()
  end

  defp reading_minutes_for_text(text) do
    words =
      text
      |> to_string()
      |> String.split(~r/\s+/, trim: true)
      |> length()

    max(1, ceil(words / 220))
  end

  defp rss_source_button_class(current_source, source) do
    base = "btn btn-xs max-w-[12rem] shrink-0 justify-start"

    if current_source == source, do: base <> " btn-secondary", else: base <> " btn-ghost"
  end

  defp rss_density_button_class(current_density, density) do
    base = "btn btn-xs"

    if current_density == density, do: base <> " btn-secondary", else: base <> " btn-ghost"
  end

  defp rss_item_button_class(item, selected_item_id, density) do
    base =
      case normalize_rss_list_density(density) do
        "compact" -> "w-full rounded-md border px-2.5 py-2 text-left transition"
        _comfortable -> "w-full rounded-lg border p-3 text-left transition"
      end

    if item.id == selected_item_id do
      base <> " border-secondary bg-secondary/10"
    else
      base <> " border-base-300 bg-base-100 hover:bg-base-200"
    end
  end

  defp parse_rss_item_id(item_id) when is_integer(item_id), do: item_id

  defp parse_rss_item_id(item_id) when is_binary(item_id) do
    case Integer.parse(item_id) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_rss_item_id(_item_id), do: nil

  defp rss_subscription_title(subscription) do
    subscription.display_name ||
      (subscription.feed && subscription.feed.title) ||
      (subscription.feed && URI.parse(subscription.feed.url).host) ||
      "Feed"
  end

  defp strip_markup(text) do
    text
    |> decode_html_entities()
    |> ElektrineWeb.HtmlHelpers.plain_text_content()
  end

  defp decode_html_entities(text) when is_binary(text), do: decode_html_entities(text, 3)
  defp decode_html_entities(text), do: text

  defp decode_html_entities(text, remaining) when remaining > 0 do
    decoded = HtmlEntities.decode(text)
    if decoded == text, do: decoded, else: decode_html_entities(decoded, remaining - 1)
  end

  defp decode_html_entities(text, _remaining), do: text

  defp safe_external_href(url) when is_binary(url) do
    case SafeExternalURL.normalize(url) do
      {:ok, safe_url} -> safe_url
      {:error, _reason} -> "#"
    end
  end

  defp safe_external_href(_url), do: "#"

  defp truncate_text(text, max_length) when is_binary(text) do
    if String.length(text) > max_length do
      text |> String.slice(0, max_length) |> String.trim() |> Kernel.<>("...")
    else
      text
    end
  end

  defp truncate_text(text, _max_length), do: text
end
