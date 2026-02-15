defmodule ElektrineWeb.Components.Social.RSSItem do
  @moduledoc """
  Component for rendering RSS feed items in the timeline.
  Styled to match the app's timeline posts.
  """
  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]
  import ElektrineWeb.CoreComponents

  @doc """
  Renders an RSS item card for the timeline.

  ## Attributes

  * `:item` - The RSS item map from RSS.get_timeline_items/2
  * `:current_user` - Current logged-in user
  * `:timezone` - User's timezone for timestamp display
  * `:time_format` - Time format preference
  * `:is_saved` - Whether the item is saved/bookmarked
  """
  attr :item, :map, required: true
  attr :current_user, :map, default: nil
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "12h"
  attr :is_saved, :boolean, default: false
  attr :id_prefix, :string, default: "rss"

  def rss_item(assigns) do
    ~H"""
    <article
      class="p-4 hover:bg-base-200/30 transition-colors border-b border-base-300 cursor-pointer"
      id={"#{@id_prefix}-item-#{@item.id}"}
    >
      <div class="flex gap-3">
        <!-- Feed Favicon -->
        <div class="flex-shrink-0">
          <div class="w-10 h-10 rounded-full bg-base-300 flex items-center justify-center overflow-hidden">
            <%= if @item.feed_favicon_url do %>
              <img
                id={"rss-favicon-#{@item.id}"}
                src={@item.feed_favicon_url}
                alt=""
                class="w-6 h-6 object-contain"
                phx-hook="ImageFallback"
                data-fallback-class="hidden"
              />
              <div class="w-6 h-6 items-center justify-center hidden" data-fallback-icon>
                <.icon name="hero-rss" class="w-5 h-5 text-warning" />
              </div>
            <% else %>
              <.icon name="hero-rss" class="w-5 h-5 text-warning" />
            <% end %>
          </div>
        </div>

        <div class="flex-1 min-w-0">
          <!-- Header -->
          <div class="flex items-center gap-2 mb-1">
            <span class="font-semibold text-sm truncate">
              {@item.feed_title || "RSS Feed"}
            </span>
            <span class="badge badge-warning badge-xs">RSS</span>
            <span class="text-xs text-base-content/50 ml-auto">
              {format_time(@item.published_at || @item.inserted_at, @timezone)}
            </span>
          </div>
          
    <!-- Title -->
          <a
            href={@item.url}
            target="_blank"
            rel="noopener noreferrer"
            class="block hover:underline"
          >
            <h3 class="font-semibold text-lg mb-2 line-clamp-2">
              {@item.title}
            </h3>
          </a>
          
    <!-- Image if present -->
          <%= if @item.image_url do %>
            <div class="mb-3 rounded-lg overflow-hidden max-h-64">
              <img
                src={@item.image_url}
                alt=""
                class="w-full h-auto object-cover max-h-64"
                loading="lazy"
              />
            </div>
          <% end %>
          
    <!-- Summary/Content -->
          <%= if @item.summary || @item.content do %>
            <div class="text-sm text-base-content/70 mb-3 line-clamp-3">
              {raw(sanitize_html(truncate_text(@item.summary || strip_html(@item.content), 300)))}
            </div>
          <% end %>
          
    <!-- Categories -->
          <%= if @item.categories && length(@item.categories) > 0 do %>
            <div class="flex flex-wrap gap-1 mb-3">
              <%= for category <- Enum.take(@item.categories, 5) do %>
                <span class="badge badge-ghost badge-sm">
                  {category}
                </span>
              <% end %>
            </div>
          <% end %>
          
    <!-- Actions -->
          <div class="flex items-center justify-between pt-2 border-t border-base-300">
            <a
              href={@item.url}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-ghost btn-sm gap-1"
            >
              <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" /> Read More
            </a>

            <div class="flex items-center gap-2">
              <!-- Save Button -->
              <%= if @current_user do %>
                <button
                  phx-click={if @is_saved, do: "unsave_rss_item", else: "save_rss_item"}
                  phx-value-item_id={@item.id}
                  class={[
                    "btn btn-ghost btn-sm gap-1",
                    @is_saved && "bg-warning/10 text-warning"
                  ]}
                  type="button"
                  title={if @is_saved, do: "Remove from saved", else: "Save for later"}
                >
                  <.icon
                    name={if @is_saved, do: "hero-bookmark-solid", else: "hero-bookmark"}
                    class="w-4 h-4"
                  />
                </button>
              <% end %>
              
    <!-- External Link -->
              <%= if @item.feed_site_url do %>
                <a
                  href={@item.feed_site_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="btn btn-ghost btn-sm gap-1 text-base-content/50"
                  title={"Visit " <> (@item.feed_title || "site")}
                >
                  <.icon name="hero-globe-alt" class="w-4 h-4" />
                </a>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </article>
    """
  end

  defp format_time(nil, _timezone), do: ""

  defp format_time(datetime, _timezone) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86400 -> "#{div(diff, 3600)}h"
      diff < 604_800 -> "#{div(diff, 86400)}d"
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end

  defp strip_html(nil), do: ""

  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp sanitize_html(text) when is_binary(text) do
    text
    |> HtmlSanitizeEx.strip_tags()
    |> HtmlEntities.decode()
  end

  defp sanitize_html(_), do: ""

  defp truncate_text(nil, _max), do: ""

  defp truncate_text(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end
end
