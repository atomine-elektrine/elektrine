defmodule ElektrineWeb.Components.Social.EmbeddedPost do
  @moduledoc """
  Component for displaying embedded/shared posts.
  """
  use Phoenix.Component
  import Phoenix.HTML
  import ElektrineWeb.CoreComponents
  import ElektrineWeb.HtmlHelpers

  @doc """
  Renders an embedded post preview card.
  """
  attr :shared_message, :map, default: nil
  attr :message, :map, default: nil
  attr :post, :map, default: nil
  attr :class, :string, default: ""

  def embedded_post(assigns) do
    # Support multiple attr names for backwards compatibility
    msg = assigns.shared_message || assigns.message || assigns.post

    # Guard against NotLoaded association or nil - don't render if not loaded
    case msg do
      nil ->
        ~H""

      %Ecto.Association.NotLoaded{} ->
        ~H""

      msg ->
        is_federated = Map.get(msg, :federated, false) && Map.get(msg, :activitypub_url)

        assigns =
          assigns
          |> assign(:shared_message, msg)
          |> assign(:post_url, get_post_url(msg))
          |> assign(:is_federated_link, is_federated)

        render_embedded_post(assigns)
    end
  end

  defp render_embedded_post(assigns) do
    ~H"""
    <div
      phx-click={if @is_federated_link, do: "open_external_link", else: "navigate_to_embedded_post"}
      phx-value-url={if @is_federated_link, do: @shared_message.activitypub_url, else: @post_url}
      phx-capture-click="stop_event"
      class={[
        "card glass-card border transition-colors cursor-pointer",
        if(@is_federated_link,
          do: "border-purple-300 hover:border-purple-500",
          else: "border-base-300 hover:border-primary/50"
        ),
        @class
      ]}
    >
      <div class="card-body p-4">
        <!-- Original Post Header -->
        <div class="flex items-center gap-2 mb-3">
          <.icon name={source_icon(get_platform(@shared_message))} class="w-4 h-4 opacity-60" />
          <span class="text-xs font-medium opacity-60">
            {format_platform_name(@shared_message)}
          </span>
          <span class="text-xs opacity-40">·</span>
          <span class="text-sm font-medium hover:underline">
            <%= if @is_federated_link && Ecto.assoc_loaded?(@shared_message.remote_actor) && @shared_message.remote_actor do %>
              @{@shared_message.remote_actor.username}@{@shared_message.remote_actor.domain}
            <% else %>
              <%= if Ecto.assoc_loaded?(@shared_message.sender) && @shared_message.sender do %>
                @{@shared_message.sender.handle || @shared_message.sender.username}@z.org
              <% else %>
                @unknown
              <% end %>
            <% end %>
          </span>
          <span class="text-xs opacity-40">·</span>
          <span class="text-xs opacity-60">
            {Elektrine.Social.time_ago_in_words(@shared_message.inserted_at)}
          </span>
          <%= if @is_federated_link do %>
            <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3 ml-auto opacity-40" />
          <% end %>
        </div>
        
    <!-- Original Post Title (if exists) -->
        <%= if @shared_message.title do %>
          <h4 class="font-semibold text-base mb-2 post-content">{@shared_message.title}</h4>
        <% end %>
        
    <!-- Content Warning Indicator for embedded posts -->
        <%= if @shared_message.content_warning && String.trim(@shared_message.content_warning) != "" do %>
          <div class="flex items-center gap-2 mb-2 text-sm text-warning bg-warning/10 border border-warning/30 rounded px-2 py-1">
            <.icon name="hero-exclamation-triangle" class="w-3 h-3 flex-shrink-0" />
            <span class="font-medium text-xs">{@shared_message.content_warning}</span>
          </div>
          <div class="text-sm opacity-70 italic mb-2">
            [Sensitive content - click to view full post]
          </div>
        <% else %>
          <!-- Original Post Content -->
          <div class="text-sm opacity-90 break-words line-clamp-4 post-content">
            {raw(preserve_line_breaks(make_content_safe_with_links(@shared_message.content)))}
          </div>
        <% end %>
        
    <!-- Original Post Media (Images and Videos) -->
        <%= if @shared_message.media_urls && !Enum.empty?(@shared_message.media_urls) do %>
          <% alt_texts =
            if @shared_message.media_metadata && @shared_message.media_metadata["alt_texts"],
              do: @shared_message.media_metadata["alt_texts"],
              else: %{} %>
          <div class="mt-3 grid grid-cols-1 gap-2">
            <%= for {media_url, idx} <- Enum.with_index(@shared_message.media_urls) do %>
              <% full_url = Elektrine.Uploads.attachment_url(media_url)
              alt_text = Map.get(alt_texts, to_string(idx), "Shared media")
              is_video = String.match?(full_url, ~r/\.(mp4|webm|ogv|mov)(\?.*)?$/i)
              is_audio = String.match?(full_url, ~r/\.(mp3|wav|ogg|m4a)(\?.*)?$/i) %>
              <%= cond do %>
                <% is_video -> %>
                  <video
                    src={full_url}
                    controls
                    preload="metadata"
                    class="rounded-lg max-h-64 w-full"
                  >
                    Your browser does not support the video tag.
                  </video>
                <% is_audio -> %>
                  <audio
                    src={full_url}
                    controls
                    preload="metadata"
                    class="w-full"
                  >
                    Your browser does not support the audio tag.
                  </audio>
                <% true -> %>
                  <img
                    src={full_url}
                    alt={alt_text}
                    class="rounded-lg max-h-64 object-cover w-full"
                    loading="lazy"
                  />
              <% end %>
            <% end %>
          </div>
        <% end %>
        
    <!-- Poll Display (simplified for embedded view) -->
        <%= if Map.get(@shared_message, :post_type) == "poll" && Ecto.assoc_loaded?(Map.get(@shared_message, :poll)) && Map.get(@shared_message, :poll) do %>
          <% poll = @shared_message.poll %>
          <div class="mt-3 p-3 bg-base-200/50 rounded-lg border border-base-300">
            <div class="flex items-center gap-2 mb-2 text-xs opacity-70">
              <.icon name="hero-chart-bar" class="w-3 h-3" />
              <span>Poll</span>
              <span>·</span>
              <span>{poll.voters_count || 0} votes</span>
            </div>
            <div class="space-y-1">
              <%= for option <- Enum.take(poll.options || [], 4) do %>
                <div class="text-sm py-1 px-2 bg-base-100 rounded flex justify-between">
                  <span>{option.title}</span>
                  <span class="opacity-60">{option.votes_count || 0}</span>
                </div>
              <% end %>
              <%= if length(poll.options || []) > 4 do %>
                <div class="text-xs opacity-60">+{length(poll.options) - 4} more options</div>
              <% end %>
            </div>
          </div>
        <% end %>
        
    <!-- Link Preview -->
        <%= if Ecto.assoc_loaded?(Map.get(@shared_message, :link_preview)) && @shared_message.link_preview && @shared_message.link_preview.status == "success" do %>
          <div class="mt-3 border border-base-300 rounded-lg overflow-hidden bg-base-200/30">
            <a
              href={@shared_message.link_preview.url}
              target="_blank"
              rel="noopener noreferrer"
              class="block"
              phx-click="stop_propagation"
            >
              <%= if @shared_message.link_preview.image_url do %>
                <div class="aspect-video bg-base-200 max-h-32">
                  <img
                    src={ensure_https(@shared_message.link_preview.image_url)}
                    alt=""
                    class="w-full h-full object-cover"
                    loading="lazy"
                    onerror="this.parentElement.style.display='none'"
                  />
                </div>
              <% end %>
              <div class="p-2">
                <div class="flex items-center gap-1 mb-1">
                  <%= if @shared_message.link_preview.favicon_url do %>
                    <img
                      src={ensure_https(@shared_message.link_preview.favicon_url)}
                      alt=""
                      class="w-3 h-3 flex-shrink-0"
                      onerror="this.style.display='none'"
                    />
                  <% end %>
                  <span class="text-xs text-base-content/50 truncate">
                    {@shared_message.link_preview.site_name ||
                      URI.parse(@shared_message.link_preview.url).host}
                  </span>
                </div>
                <%= if @shared_message.link_preview.title do %>
                  <h5 class="font-medium text-xs line-clamp-1">
                    {String.slice(@shared_message.link_preview.title, 0, 80)}
                  </h5>
                <% end %>
              </div>
            </a>
          </div>
        <% end %>
        
    <!-- Original Post Stats -->
        <div class="flex items-center gap-4 mt-3 text-xs opacity-60">
          <%= if @shared_message.like_count && @shared_message.like_count > 0 do %>
            <span>{@shared_message.like_count} likes</span>
          <% end %>
          <%= if @shared_message.reply_count && @shared_message.reply_count > 0 do %>
            <span>{@shared_message.reply_count} replies</span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp get_platform(%Ecto.Association.NotLoaded{}), do: "unknown"
  defp get_platform(%{conversation: %{type: type}}), do: type
  defp get_platform(_), do: "unknown"

  defp format_platform_name(%Ecto.Association.NotLoaded{}), do: "Post"
  defp format_platform_name(%{conversation: %{type: "timeline"}}), do: "Timeline"
  defp format_platform_name(%{conversation: %{type: "community", name: name}}), do: name
  defp format_platform_name(%{conversation: %{type: "chat"}}), do: "Chat"
  defp format_platform_name(_), do: "Post"

  defp get_post_url(%{
         id: message_id,
         reply_to_id: reply_to_id,
         conversation: %{type: "timeline"}
       })
       when not is_nil(reply_to_id),
       do: "/timeline/post/#{reply_to_id}#message-#{message_id}"

  defp get_post_url(%{id: message_id, conversation: %{type: "timeline"}}),
    do: "/timeline/post/#{message_id}"

  defp get_post_url(%{
         id: message_id,
         reply_to_id: reply_to_id,
         conversation: %{type: "community", name: name}
       })
       when not is_nil(reply_to_id),
       do: "/discussions/#{name}/post/#{reply_to_id}#message-#{message_id}"

  defp get_post_url(%{id: message_id, conversation: %{type: "community", name: name}}),
    do: "/discussions/#{name}/post/#{message_id}"

  defp get_post_url(%{id: message_id, conversation: %{type: "chat", hash: hash}})
       when not is_nil(hash),
       do: "/chat/#{hash}#message-#{message_id}"

  defp get_post_url(%{id: message_id, conversation: %{type: "chat", id: conv_id}}),
    do: "/chat/#{conv_id}#message-#{message_id}"

  defp get_post_url(%{id: message_id}),
    do: "/timeline/post/#{message_id}"

  defp get_post_url(%Ecto.Association.NotLoaded{}),
    do: "#"

  defp get_post_url(_),
    do: "#"

  defp source_icon("timeline"), do: "hero-rectangle-stack"
  defp source_icon("community"), do: "hero-user-group"
  defp source_icon("chat"), do: "hero-chat-bubble-left-right"
  defp source_icon("dm"), do: "hero-user"
  defp source_icon(_), do: "hero-arrows-right-left"
end
