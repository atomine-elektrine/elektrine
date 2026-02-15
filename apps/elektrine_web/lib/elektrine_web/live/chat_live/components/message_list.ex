defmodule ElektrineWeb.ChatLive.Components.MessageList do
  use ElektrineWeb, :live_component
  import Phoenix.HTML
  import ElektrineWeb.HtmlHelpers

  alias Elektrine.Messaging.Message

  def render(assigns) do
    # Group consecutive messages from same sender within 5 minutes
    messages_with_grouping = group_messages(assigns.messages)
    assigns = assign(assigns, :messages_with_grouping, messages_with_grouping)

    ~H"""
    <div class="flex-1 overflow-y-auto p-4 space-y-1" id="messages-container" phx-hook="MessageList">
      <%= for {message, is_grouped} <- @messages_with_grouping do %>
        <div class={[
          "chat group",
          if(message.sender_id == @current_user.id, do: "chat-end", else: "chat-start"),
          if(is_grouped, do: "mt-0.5", else: "mt-3 first:mt-0")
        ]}>
          <!-- Avatar (hidden for grouped messages) -->
          <%= if !is_grouped do %>
            <button
              phx-click="show_user_profile"
              phx-value-user_id={message.sender_id}
              class="chat-image avatar"
              title={"View #{message.sender.handle || message.sender.username}'s profile"}
              aria-label={"View #{message.sender.handle || message.sender.username}'s profile"}
            >
              <div class="w-8 rounded-full">
                <%= if message.sender.avatar do %>
                  <img
                    src={message.sender.avatar}
                    alt={message.sender.handle || message.sender.username}
                  />
                <% else %>
                  <div class="bg-accent text-accent-content w-8 h-8 rounded-full flex items-center justify-center text-xs">
                    {String.upcase(String.first(message.sender.handle || message.sender.username))}
                  </div>
                <% end %>
              </div>
            </button>
          <% else %>
            <!-- Spacer to align grouped messages -->
            <div class="chat-image w-8"></div>
          <% end %>
          
    <!-- Header (hidden for grouped messages) -->
          <%= if !is_grouped do %>
            <div class="chat-header">
              <%= if @conversation.type != "dm" or message.sender_id != @current_user.id do %>
                <span class="font-medium">{message.sender.handle || message.sender.username}</span>
              <% end %>
              <time class="text-xs opacity-50">
                <.local_time
                  datetime={message.inserted_at}
                  format="time"
                  timezone={@timezone}
                  time_format={@time_format}
                />
              </time>
            </div>
          <% end %>
          
    <!-- Message Bubble -->
          <div class={[
            "chat-bubble",
            if(message.sender_id == @current_user.id, do: "chat-bubble-primary", else: "")
          ]}>
            <!-- Reply Context -->
            <%= if message.reply_to do %>
              <% reply_content = Message.display_content(message.reply_to) || "" %>
              <div class="mb-2 px-2 py-1 bg-base-300/30 rounded text-xs opacity-75 border-l-2 border-primary">
                <span class="font-medium">
                  Replying to {message.reply_to.sender.handle || message.reply_to.sender.username}
                </span>
                <%= if reply_content != "" do %>
                  <p class="truncate opacity-75">
                    {String.slice(reply_content, 0, 50)}{if String.length(reply_content) > 50,
                      do: "..."}
                  </p>
                <% end %>
              </div>
            <% end %>
            
    <!-- Message Content -->
            <div class="message-content">
              {raw(
                Message.display_content(message)
                |> make_content_safe_with_links()
                |> render_custom_emojis()
                |> preserve_line_breaks()
              )}
            </div>
            
    <!-- Media Files -->
            <%= if message.media_urls != [] do %>
              <% image_urls =
                Enum.filter(message.media_urls, &String.match?(&1, ~r/\.(jpg|jpeg|png|gif|webp)$/i)) %>
              <div class="mt-2 space-y-2">
                <%= for {media_url, idx} <- Enum.with_index(message.media_urls) do %>
                  <%= if String.match?(media_url, ~r/\.(jpg|jpeg|png|gif|webp)$/i) do %>
                    <button
                      type="button"
                      phx-click="open_image_modal"
                      phx-value-images={Jason.encode!(image_urls)}
                      phx-value-index={Enum.find_index(image_urls, &(&1 == media_url)) || idx}
                      phx-value-message_id={message.id}
                      class="image-zoom-trigger max-w-full rounded-lg overflow-hidden"
                    >
                      <img
                        src={media_url}
                        alt="Shared image"
                        class="max-w-full rounded-lg"
                      />
                    </button>
                  <% else %>
                    <a
                      href={media_url}
                      target="_blank"
                      class="flex items-center gap-2 text-sm underline"
                    >
                      <.icon name="hero-paper-clip" class="w-4 h-4" /> File
                    </a>
                  <% end %>
                <% end %>
              </div>
            <% end %>
            
    <!-- Reactions inside bubble -->
            <%= if message.reactions != [] do %>
              <div class="flex gap-1 mt-2 flex-wrap">
                <%= for {emoji, count, users} <- format_reactions(message.reactions) do %>
                  <button
                    phx-click="react_to_message"
                    phx-value-message_id={message.id}
                    phx-value-emoji={emoji}
                    phx-target={@myself}
                    class={[
                      "px-2 py-0.5 rounded-full text-xs border flex items-center gap-1",
                      if user_reacted?(message.reactions, emoji, @current_user.id) do
                        "bg-primary/20 border-primary"
                      else
                        "bg-base-200/50 border-base-300 hover:bg-base-200"
                      end
                    ]}
                    title={Enum.join(users, ", ")}
                  >
                    {raw(render_custom_emojis(emoji))} {count}
                  </button>
                <% end %>
              </div>
            <% end %>
          </div>
          
    <!-- Footer: Actions (visible on hover, always visible on mobile) -->
          <div class="chat-footer">
            <div class="flex gap-1 opacity-0 group-hover:opacity-100 sm:group-hover:opacity-100 transition-opacity">
              <button
                phx-click="reply_to_message"
                phx-value-message_id={message.id}
                phx-target={@myself}
                class="btn btn-xs btn-ghost"
                title="Reply"
                aria-label="Reply to message"
              >
                <.icon name="hero-arrow-uturn-left" class="w-3 h-3" />
              </button>

              <button
                phx-click="react_to_message"
                phx-value-message_id={message.id}
                phx-value-emoji="👍"
                phx-target={@myself}
                class="btn btn-xs btn-ghost"
                title="React with thumbs up"
                aria-label="React with thumbs up"
              >
                <.icon name="hero-hand-thumb-up" class="w-3 h-3" />
              </button>
              
    <!-- More actions dropdown -->
              <div class="dropdown dropdown-end">
                <label tabindex="0" class="btn btn-xs btn-ghost" aria-label="More actions">
                  <.icon name="hero-ellipsis-horizontal" class="w-3 h-3" />
                </label>
                <ul
                  tabindex="0"
                  class="dropdown-content z-50 menu p-1 shadow-lg bg-base-100 rounded-box w-32 border border-base-300"
                >
                  <li>
                    <button
                      phx-click="reply_to_message"
                      phx-value-message_id={message.id}
                      phx-target={@myself}
                    >
                      <.icon name="hero-arrow-uturn-left" class="w-3 h-3" /> Reply
                    </button>
                  </li>
                  <li>
                    <button
                      phx-click="copy_message"
                      phx-value-message_id={message.id}
                      phx-target={@myself}
                    >
                      <.icon name="hero-clipboard" class="w-3 h-3" /> Copy
                    </button>
                  </li>
                  <%= if message.sender_id == @current_user.id do %>
                    <li>
                      <button
                        phx-click="delete_message"
                        phx-value-message_id={message.id}
                        phx-target={@myself}
                        class="text-error"
                      >
                        <.icon name="hero-trash" class="w-3 h-3" /> Delete
                      </button>
                    </li>
                  <% end %>
                </ul>
              </div>
            </div>
            <!-- Time shown on hover for grouped messages -->
            <%= if is_grouped do %>
              <time class="text-xs opacity-0 group-hover:opacity-50 transition-opacity">
                <.local_time
                  datetime={message.inserted_at}
                  format="time"
                  timezone={@timezone}
                  time_format={@time_format}
                />
              </time>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  def handle_event("react_to_message", %{"message_id" => message_id, "emoji" => emoji}, socket) do
    send(self(), {:react_to_message, message_id, emoji})
    {:noreply, socket}
  end

  def handle_event("reply_to_message", %{"message_id" => message_id}, socket) do
    send(self(), {:reply_to_message, message_id})
    {:noreply, socket}
  end

  def handle_event("copy_message", %{"message_id" => message_id}, socket) do
    send(self(), {:copy_message, message_id})
    {:noreply, socket}
  end

  def handle_event("delete_message", %{"message_id" => message_id}, socket) do
    send(self(), {:delete_message, message_id})
    {:noreply, socket}
  end

  # Group consecutive messages from the same sender within 5 minutes
  defp group_messages(messages) do
    messages
    |> Enum.with_index()
    |> Enum.map(fn {message, index} ->
      is_grouped =
        if index > 0 do
          prev_message = Enum.at(messages, index - 1)

          same_sender = prev_message.sender_id == message.sender_id

          within_time_window =
            case {prev_message.inserted_at, message.inserted_at} do
              {prev_time, curr_time} when not is_nil(prev_time) and not is_nil(curr_time) ->
                diff = DateTime.diff(curr_time, prev_time, :second)
                # 5 minutes
                diff < 300

              _ ->
                false
            end

          same_sender && within_time_window
        else
          false
        end

      {message, is_grouped}
    end)
  end

  defp format_reactions(reactions) do
    reactions
    |> Enum.group_by(& &1.emoji)
    |> Enum.map(fn {emoji, reactions} ->
      users = Enum.map(reactions, &(&1.user.handle || &1.user.username))
      {emoji, length(reactions), users}
    end)
  end

  defp user_reacted?(reactions, emoji, user_id) do
    Enum.any?(reactions, fn reaction ->
      reaction.emoji == emoji and reaction.user.id == user_id
    end)
  end
end
