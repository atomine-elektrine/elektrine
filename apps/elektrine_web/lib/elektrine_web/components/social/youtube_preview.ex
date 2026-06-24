defmodule ElektrineWeb.Components.Social.YoutubePreview do
  @moduledoc false
  use Phoenix.Component

  alias Elektrine.Social.Message
  import ElektrineWeb.HtmlHelpers, only: [safe_external_href: 1, safe_external_image_url: 1]

  attr :url, :string, required: true
  attr :title, :string, default: nil
  attr :show_title, :boolean, default: false

  attr :wrapper_class, :string, default: "mt-3 border border-base-200 rounded-lg overflow-hidden"

  def youtube_preview(assigns) do
    assigns = assign(assigns, :embed_url, Message.extract_youtube_embed_url(assigns.url))

    ~H"""
    <%= if @embed_url do %>
      <div class={@wrapper_class}>
        <div class="aspect-video bg-base-200">
          <iframe
            src={@embed_url}
            title={@title || "YouTube video"}
            loading="lazy"
            frameborder="0"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
            allowfullscreen
            class="w-full h-full"
          >
          </iframe>
        </div>
        <%= if @show_title && @title do %>
          <div class="p-3 border-t border-base-200">
            <h4 class="font-medium text-sm">{@title}</h4>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  attr :url, :string, required: true
  attr :preview, :map, default: nil
  attr :wrapper_class, :string, default: "mt-3"
  attr :card_class, :string, default: "border border-base-200 rounded-lg overflow-hidden"
  attr :fallback_card_class, :string, default: "border border-base-300 rounded-lg overflow-hidden"

  def rich_link_preview(assigns) do
    preview =
      case assigns.preview do
        %{status: "success"} = preview -> preview
        _ -> nil
      end

    assigns =
      assigns
      |> assign(:preview, preview)
      |> assign(:embed_url, Message.extract_youtube_embed_url(assigns.url))
      |> assign(:safe_url, safe_external_href(assigns.url))
      |> assign(:host, safe_preview_host(assigns.url))

    ~H"""
    <%= cond do %>
      <% @embed_url -> %>
        <div class={@wrapper_class}>
          <.youtube_preview
            url={@url}
            title={@preview && @preview.title}
            show_title={!!(@preview && @preview.title)}
            wrapper_class={@card_class}
          />
          <%= if @preview && @preview.description do %>
            <div class="px-4 pb-4 pt-2 border-x border-b border-base-200 rounded-b-lg">
              <p class="text-sm opacity-70 line-clamp-2">{@preview.description}</p>
            </div>
          <% end %>
        </div>
      <% @preview && @safe_url -> %>
        <a
          href={@safe_url}
          target="_blank"
          rel="noopener noreferrer"
          class={["block", @wrapper_class, @card_class]}
        >
          <%= if preview_image_url = safe_external_image_url(@preview.image_url) do %>
            <div class="aspect-video bg-base-200 relative overflow-hidden">
              <img
                src={preview_image_url}
                alt={@preview.title || "Link preview"}
                class="w-full h-full object-cover"
              />
            </div>
          <% end %>
          <div class="p-3 bg-base-100">
            <%= if @preview.title do %>
              <h4 class="font-medium text-sm mb-1 line-clamp-2">{@preview.title}</h4>
            <% end %>
            <%= if @preview.description do %>
              <p class="text-xs opacity-70 line-clamp-2">{@preview.description}</p>
            <% end %>
            <div class="flex items-center gap-2 mt-2 text-xs opacity-50">
              <%= if favicon_url = safe_external_image_url(@preview.favicon_url) do %>
                <img
                  id={"youtube-preview-favicon-#{:erlang.phash2(@preview.favicon_url)}"}
                  src={favicon_url}
                  alt=""
                  class="w-4 h-4"
                  phx-hook="ImageFallback"
                />
              <% end %>
              <span class="truncate">{@host}</span>
            </div>
          </div>
        </a>
      <% @safe_url -> %>
        <div class={["block", @wrapper_class, @fallback_card_class]}>
          <div class="bg-base-200/50 p-4 flex items-center gap-3">
            <span class="ui-icon hero-arrow-top-right-on-square w-5 h-5 flex-shrink-0"></span>
            <div class="flex-1 min-w-0">
              <div class="font-medium text-sm truncate">{@host}</div>
              <a
                href={@safe_url}
                target="_blank"
                rel="noopener noreferrer"
                class="text-xs opacity-70 truncate hover:text-primary"
              >
                {@safe_url}
              </a>
            </div>
          </div>
        </div>
      <% true -> %>
        <% nil %>
    <% end %>
    """
  end

  defp safe_preview_host(url) do
    case safe_external_href(url) do
      nil -> ""
      safe_url -> URI.parse(safe_url).host || safe_url
    end
  end
end
