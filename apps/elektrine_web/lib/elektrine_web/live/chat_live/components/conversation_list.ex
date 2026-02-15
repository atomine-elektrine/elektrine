defmodule ElektrineWeb.ChatLive.Components.ConversationList do
  use ElektrineWeb, :live_component

  alias Elektrine.Messaging.{Conversation, Message}

  def render(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto">
      <%= for conversation <- @conversations do %>
        <.link
          patch={~p"/chat/#{conversation.id}"}
          class={[
            "flex items-center gap-3 p-4 hover:bg-base-300 cursor-pointer border-b border-base-300",
            @selected_conversation && @selected_conversation.id == conversation.id && "bg-primary/10"
          ]}
        >
          <div class="avatar">
            <div class="w-12 h-12 rounded-full">
              <%= if conversation_avatar(conversation, @current_user.id) do %>
                <img src={conversation_avatar(conversation, @current_user.id)} alt="" />
              <% else %>
                <div class="bg-primary text-primary-content flex items-center justify-center w-12 h-12">
                  <%= if conversation.type == "dm" do %>
                    {String.upcase(String.first(conversation_name(conversation, @current_user.id)))}
                  <% else %>
                    <.icon name="hero-users" class="w-6 h-6" />
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <div class="flex-1 min-w-0">
            <div class="flex items-center justify-between">
              <p class="font-medium truncate">
                {conversation_name(conversation, @current_user.id)}
              </p>
              <div class="flex items-center gap-2">
                <%= if conversation.last_message_at do %>
                  <span class="text-xs opacity-70">
                    <.local_time datetime={conversation.last_message_at} format="time" />
                  </span>
                <% end %>
                <%= if Map.get(@unread_counts, conversation.id, 0) > 0 do %>
                  <div class="badge badge-primary badge-sm">
                    {Map.get(@unread_counts, conversation.id)}
                  </div>
                <% end %>
              </div>
            </div>

            <%= if conversation.messages != [] do %>
              <% last_message = List.first(conversation.messages) %>
              <p class="text-sm opacity-70 truncate">
                <%= if last_message.sender_id == @current_user.id do %>
                  You: {Message.display_content(last_message)}
                <% else %>
                  {Message.display_content(last_message)}
                <% end %>
              </p>
            <% else %>
              <p class="text-sm opacity-70">No messages yet</p>
            <% end %>
          </div>

          <%= if conversation.type != "dm" do %>
            <div class="text-xs opacity-70">
              {conversation.member_count} members
            </div>
          <% end %>
        </.link>
      <% end %>

      <%= if @conversations == [] do %>
        <div class="text-center p-8">
          <.icon name="hero-chat-bubble-left-right" class="w-12 h-12 mx-auto opacity-50 mb-4" />
          <p class="opacity-70">No conversations yet</p>
          <p class="text-sm opacity-50">Start a new chat to begin messaging</p>
        </div>
      <% end %>
    </div>
    """
  end

  defp conversation_avatar(conversation, current_user_id) do
    Conversation.avatar_url(conversation, current_user_id)
  end

  defp conversation_name(conversation, current_user_id) do
    Conversation.display_name(conversation, current_user_id)
  end
end
