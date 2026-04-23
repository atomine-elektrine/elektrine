defmodule ElektrineWeb.Components.Social.YoutubePreview do
  @moduledoc false
  use Phoenix.Component

  alias Elektrine.Social.Message
  import ElektrineWeb.HtmlHelpers, only: [ensure_https: 1]

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
      |> assign(:host, URI.parse(assigns.url).host || assigns.url)

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
      <% @preview -> %>
        <a
          href={@url}
          target="_blank"
          rel="noopener noreferrer"
          class={["block", @wrapper_class, @card_class]}
        >
          <%= if @preview.image_url do %>
            <div class="aspect-video bg-base-200 relative overflow-hidden">
              <img
                src={ensure_https(@preview.image_url)}
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
              <%= if @preview.favicon_url do %>
                <img
                  id={"youtube-preview-favicon-#{:erlang.phash2(@preview.favicon_url)}"}
                  src={ensure_https(@preview.favicon_url)}
                  alt=""
                  class="w-4 h-4"
                  phx-hook="ImageFallback"
                />
              <% end %>
              <span class="truncate">{@host}</span>
            </div>
          </div>
        </a>
      <% true -> %>
        <div class={["block", @wrapper_class, @fallback_card_class]}>
          <div class="bg-base-200/50 p-4 flex items-center gap-3">
            <span class="ui-icon hero-arrow-top-right-on-square w-5 h-5 flex-shrink-0"></span>
            <div class="flex-1 min-w-0">
              <div class="font-medium text-sm truncate">{@host}</div>
              <a
                href={@url}
                target="_blank"
                rel="noopener noreferrer"
                class="text-xs opacity-70 truncate hover:text-primary"
              >
                {@url}
              </a>
            </div>
          </div>
        </div>
    <% end %>
    """
  end
end
