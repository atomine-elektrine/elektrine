defmodule ElektrineSocialWeb.Components.Social.TimelinePostMedia do
  @moduledoc false

  use Phoenix.Component

  import ElektrineWeb.Components.Social.YoutubePreview, only: [youtube_preview: 1]

  alias ElektrineSocialWeb.Components.Social.PostUtilities

  @default_image_aspect_ratio {3, 2}
  @default_video_aspect_ratio {16, 9}

  attr :post, :map, required: true

  def youtube_embed(assigns) do
    has_link_preview = link_preview_success?(assigns.post.link_preview)

    youtube_url =
      if !has_link_preview && assigns.post.content,
        do: Elektrine.Social.Message.extract_youtube_embed_url(assigns.post.content),
        else: nil

    assigns = assign(assigns, :youtube_url, youtube_url)

    ~H"""
    <%= if @youtube_url do %>
      <div>
        <.youtube_preview url={@youtube_url} wrapper_class="mt-3 rounded-lg overflow-hidden" />
      </div>
    <% end %>
    """
  end

  attr :post, :map, required: true
  attr :is_gallery_post, :boolean, default: false
  attr :on_image_click, :string, default: "open_image_modal"
  attr :id_prefix, :string, default: "post"

  def content_images(assigns) do
    image_urls = Elektrine.Social.Message.extract_image_urls(assigns.post.content)

    assigns =
      assigns
      |> assign(:image_urls, image_urls)
      |> assign(
        :content_image_frame_style,
        media_frame_style(nil, nil, @default_image_aspect_ratio)
      )

    ~H"""
    <%= if @image_urls != [] do %>
      <div class="mt-3 space-y-2">
        <%= for {image_url, idx} <- Enum.with_index(@image_urls) do %>
          <button
            type="button"
            phx-click={@on_image_click}
            phx-value-id={@post.id}
            phx-value-url={image_url}
            phx-value-images={Jason.encode!(@image_urls)}
            phx-value-index={idx}
            phx-value-post_id={@post.id}
            class="block w-full overflow-hidden rounded-lg bg-base-200/55"
            style={@content_image_frame_style}
          >
            <img
              id={"#{@id_prefix}-content-image-#{@post.id}-#{idx}-#{:erlang.phash2(image_url)}"}
              src={image_url}
              alt="Image preview"
              class="h-full w-full object-contain hover:opacity-90 transition-opacity cursor-pointer"
              loading="lazy"
              phx-hook="ImageFallback"
              data-hide-target="closest"
              data-hide-selector="button"
            />
          </button>
        <% end %>
      </div>
    <% end %>
    """
  end

  attr :post, :map, required: true
  attr :is_gallery_post, :boolean, default: false
  attr :on_image_click, :string, default: "open_image_modal"
  attr :id_prefix, :string, default: "post"

  def media_attachments(assigns) do
    media_entries = build_media_entries(assigns.post)
    full_media_urls = Enum.map(media_entries, & &1.full_url)
    sensitive? = sensitive_post?(assigns.post)

    assigns =
      assigns
      |> assign(:media_entries, media_entries)
      |> assign(:full_media_urls, full_media_urls)
      |> assign(:sensitive?, sensitive?)

    ~H"""
    <%= if @media_entries != [] do %>
      <div
        class={[
          "mt-3 grid grid-cols-1 gap-2 transition-all",
          @sensitive? && "blur-sm hover:blur-none focus-within:blur-none"
        ]}
        tabindex={if @sensitive?, do: "0", else: nil}
      >
        <%= for media_entry <- @media_entries do %>
          <%= cond do %>
            <% media_entry.is_video -> %>
              <div
                class="w-full overflow-hidden rounded-lg bg-base-200/55"
                style={media_entry.frame_style}
              >
                <video
                  src={media_entry.full_url}
                  controls
                  preload="metadata"
                  class="h-full w-full object-contain"
                >
                  Your browser does not support the video tag.
                </video>
              </div>
            <% media_entry.is_audio -> %>
              <audio src={media_entry.full_url} controls preload="metadata" class="w-full">
                Your browser does not support the audio tag.
              </audio>
            <% true -> %>
              <button
                type="button"
                phx-click={@on_image_click}
                phx-value-id={@post.id}
                phx-value-url={media_entry.full_url}
                phx-value-images={Jason.encode!(@full_media_urls)}
                phx-value-index={media_entry.index}
                phx-value-post_id={@post.id}
                class="block w-full overflow-hidden rounded-lg bg-base-200/55"
                style={media_entry.frame_style}
              >
                <img
                  id={"#{@id_prefix}-media-image-#{@post.id}-#{media_entry.index}-#{:erlang.phash2(media_entry.full_url)}"}
                  src={media_entry.full_url}
                  alt={media_entry.alt_text}
                  width={media_entry.width}
                  height={media_entry.height}
                  class="h-full w-full object-contain cursor-pointer hover:opacity-90 transition-opacity"
                  loading="lazy"
                  phx-hook="ImageFallback"
                  data-hide-target="closest"
                  data-hide-selector="button"
                />
              </button>
          <% end %>
        <% end %>
      </div>
    <% end %>
    """
  end

  attr :post, :map, required: true
  attr :id_prefix, :string, default: "post"

  def link_preview(assigns) do
    assigns = assign(assigns, :link_preview, PostUtilities.visible_link_preview(assigns.post))

    ~H"""
    <%= if @link_preview && PostUtilities.safe_external_href(@link_preview.url) do %>
      <div class="mt-3 border border-base-300 rounded-lg overflow-hidden hover:border-base-300 transition-colors max-w-full">
        <a
          href={PostUtilities.safe_external_href(@link_preview.url)}
          target="_blank"
          rel="noopener noreferrer"
          class="block min-w-0"
        >
          <%= if image_url = PostUtilities.safe_image_url(@link_preview.image_url) do %>
            <div class="aspect-video bg-base-50">
              <img
                id={"#{@id_prefix}-link-preview-image-#{@post.id || :erlang.phash2(@link_preview.image_url)}"}
                src={image_url}
                alt={@link_preview.title || ""}
                class="w-full h-full object-cover"
                phx-hook="ImageFallback"
                data-hide-target="parent"
              />
            </div>
          <% end %>
          <div class="p-3 min-w-0">
            <div class="flex items-center gap-2 mb-2">
              <%= if favicon_url = PostUtilities.safe_image_url(@link_preview.favicon_url) do %>
                <img
                  id={"#{@id_prefix}-link-preview-favicon-#{@post.id || :erlang.phash2(@link_preview.favicon_url)}"}
                  src={favicon_url}
                  alt=""
                  class="w-4 h-4 flex-shrink-0"
                  phx-hook="ImageFallback"
                />
              <% end %>
              <span class="text-xs text-base-content/60 truncate">
                {@link_preview.site_name || safe_preview_host(@link_preview)}
              </span>
            </div>
            <%= if @link_preview.title do %>
              <h4 class="font-medium text-sm mb-1 break-words">
                {preview_display_text(@link_preview.title, 100)}
              </h4>
            <% end %>
            <%= if @link_preview.description do %>
              <p class="text-xs text-base-content/70 break-words">
                {preview_display_text(@link_preview.description, 200)}
              </p>
            <% end %>
          </div>
        </a>
      </div>
    <% end %>
    """
  end

  def attachment_url_for_render(media_url, post) do
    if Map.get(post, :federated) == true && is_binary(media_url) &&
         String.starts_with?(media_url, ["http://", "https://"]) do
      media_url
    else
      case Elektrine.Uploads.attachment_url(media_url, post) do
        url when is_binary(url) and url != "" -> url
        _ -> nil
      end
    end
  end

  def link_preview_success?(preview) do
    social_link_preview?(preview) and Map.get(preview, :status) == "success"
  end

  def safe_preview_host(preview) do
    with url when is_binary(url) <- Map.get(preview, :url),
         safe_url when is_binary(safe_url) <- PostUtilities.safe_external_href(url),
         %URI{host: host} when is_binary(host) <- URI.parse(safe_url) do
      host
    else
      _ -> nil
    end
  end

  defp build_media_entries(post) do
    metadata = media_metadata(post)
    alt_texts = media_alt_texts(metadata)
    attachments = attachment_metadata(metadata)

    (post.media_urls || [])
    |> Enum.with_index()
    |> Enum.reduce([], fn {media_url, index}, entries ->
      case attachment_url_for_render(media_url, post) do
        full_url when is_binary(full_url) and full_url != "" ->
          attachment = Enum.at(attachments, index)
          {width, height} = media_dimensions(metadata, attachments, index)
          is_video = PostUtilities.video_url?(full_url) || video_attachment?(attachment)
          is_audio = PostUtilities.audio_url?(full_url) || audio_attachment?(attachment)

          fallback_ratio =
            if is_video, do: @default_video_aspect_ratio, else: @default_image_aspect_ratio

          [
            %{
              alt_text:
                Map.get(alt_texts, to_string(index)) ||
                  attachment_alt_text(Enum.at(attachments, index)) ||
                  "Posted media",
              frame_style: media_frame_style(width, height, fallback_ratio),
              full_url: full_url,
              height: height,
              index: index,
              is_audio: is_audio,
              is_video: is_video,
              width: width
            }
            | entries
          ]

        _ ->
          entries
      end
    end)
    |> Enum.reverse()
  end

  defp sensitive_post?(post) when is_map(post) do
    Elektrine.Strings.present?(Map.get(post, :content_warning)) ||
      Map.get(post, :sensitive) == true ||
      Map.get(post, "sensitive") == true
  end

  defp media_metadata(post) do
    Map.get(post, :media_metadata) || Map.get(post, "media_metadata") || %{}
  end

  defp media_alt_texts(metadata) when is_map(metadata) do
    case Map.get(metadata, "alt_texts") || Map.get(metadata, :alt_texts) do
      alt_texts when is_map(alt_texts) -> alt_texts
      _ -> %{}
    end
  end

  defp media_alt_texts(_metadata), do: %{}

  defp attachment_metadata(metadata) when is_map(metadata) do
    case Map.get(metadata, "attachments") || Map.get(metadata, :attachments) ||
           Map.get(metadata, "media_attachments") || Map.get(metadata, :media_attachments) do
      attachments when is_list(attachments) ->
        Enum.filter(attachments, &is_map/1)

      _ ->
        []
    end
  end

  defp attachment_metadata(_metadata), do: []

  defp media_dimensions(metadata, attachments, index) do
    attachment = Enum.at(attachments, index)

    width =
      attachment_dimension(attachment, "width") ||
        legacy_media_dimension(metadata, "widths", index)

    height =
      attachment_dimension(attachment, "height") ||
        legacy_media_dimension(metadata, "heights", index)

    {width, height}
  end

  defp attachment_dimension(attachment, key) when is_map(attachment) do
    atom_key =
      case key do
        "width" -> :width
        "height" -> :height
      end

    positive_integer(Map.get(attachment, key) || Map.get(attachment, atom_key))
  end

  defp attachment_dimension(_attachment, _key), do: nil

  defp attachment_alt_text(attachment) when is_map(attachment) do
    case Map.get(attachment, "alt_text") || Map.get(attachment, :alt_text) do
      alt_text when is_binary(alt_text) and alt_text != "" -> alt_text
      _ -> nil
    end
  end

  defp attachment_alt_text(_attachment), do: nil

  defp video_attachment?(attachment), do: attachment_media_type?(attachment, "video/")

  defp audio_attachment?(attachment), do: attachment_media_type?(attachment, "audio/")

  defp attachment_media_type?(attachment, prefix) when is_map(attachment) do
    type =
      attachment
      |> Map.get("mediaType")
      |> Kernel.||(Map.get(attachment, :mediaType))
      |> Kernel.||(Map.get(attachment, "media_type"))
      |> Kernel.||(Map.get(attachment, :media_type))
      |> Kernel.||(Map.get(attachment, "type"))
      |> Kernel.||(Map.get(attachment, :type))
      |> to_string()
      |> String.downcase()

    String.starts_with?(type, prefix) ||
      (prefix == "video/" &&
         type in ["video", "application/x-mpegurl", "application/vnd.apple.mpegurl"]) ||
      (prefix == "audio/" && type == "audio")
  end

  defp attachment_media_type?(_, _), do: false

  defp legacy_media_dimension(metadata, key, index) when is_map(metadata) do
    atom_key =
      case key do
        "widths" -> :widths
        "heights" -> :heights
      end

    case Map.get(metadata, key) || Map.get(metadata, atom_key) do
      values when is_map(values) ->
        positive_integer(Map.get(values, to_string(index)) || Map.get(values, index))

      values when is_list(values) ->
        positive_integer(Enum.at(values, index))

      _ ->
        nil
    end
  end

  defp legacy_media_dimension(_metadata, _key, _index), do: nil

  defp media_frame_style(width, height, fallback_ratio) do
    {aspect_width, aspect_height} =
      case {positive_integer(width), positive_integer(height)} do
        {nil, nil} -> fallback_ratio
        {nil, _} -> fallback_ratio
        {_, nil} -> fallback_ratio
        {valid_width, valid_height} -> {valid_width, valid_height}
      end

    "aspect-ratio: #{aspect_width} / #{aspect_height};"
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp preview_display_text(text, max_len) when is_binary(text) and is_integer(max_len) do
    text
    |> decode_preview_entities()
    |> String.slice(0, max_len)
  end

  defp preview_display_text(_, _), do: nil

  defp decode_preview_entities(text), do: decode_preview_entities(text, 3)

  defp decode_preview_entities(text, remaining) when is_binary(text) and remaining > 0 do
    decoded = HtmlEntities.decode(text)
    if decoded == text, do: decoded, else: decode_preview_entities(decoded, remaining - 1)
  end

  defp decode_preview_entities(text, _), do: text

  defp social_link_preview?(%{__struct__: :"Elixir.Elektrine.Social.LinkPreview"}), do: true
  defp social_link_preview?(_), do: false
end
