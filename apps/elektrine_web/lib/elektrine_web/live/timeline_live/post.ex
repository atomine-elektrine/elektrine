defmodule ElektrineWeb.TimelineLive.Post do
  use ElektrineWeb, :live_view
  import ElektrineWeb.Components.Social.ContentJourney
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.Social.EmbeddedPost
  import ElektrineWeb.HtmlHelpers
  import ElektrineWeb.Components.User.Avatar
  import ElektrineWeb.Components.User.UsernameEffects
  use Phoenix.Component

  alias Elektrine.Messaging.Messages, as: MessagingMessages
  alias Elektrine.Social

  # Recursive component to render nested replies
  attr :reply, :map, required: true
  attr :post, :map, default: nil
  attr :current_user, :map, default: nil
  attr :reply_to_reply_id, :any, default: nil
  attr :reply_content, :string, default: ""
  attr :depth, :integer, default: 0
  attr :liked_replies, :map, default: %{}
  attr :timezone, :string, default: "Etc/UTC"
  attr :time_format, :string, default: "12"

  def render_reply(assigns) do
    # Different colors for each depth level
    border_color =
      case rem(assigns.depth, 5) do
        0 -> "border-purple-500/60"
        1 -> "border-cyan-500/60"
        2 -> "border-orange-500/60"
        3 -> "border-pink-500/60"
        4 -> "border-green-500/60"
        _ -> "border-purple-500/60"
      end

    indent_class =
      if assigns.depth > 0 do
        "ml-#{min(assigns.depth * 4, 12)} border-l-2 #{border_color} pl-4"
      else
        ""
      end

    assigns =
      assigns
      |> assign(:max_depth, 5)
      |> assign(:indent_class, indent_class)

    ~H"""
    <div class={@indent_class}>
      <div class="card bg-base-50 border border-base-200 shadow-sm" id={"reply-#{@reply.id}"}>
        <div class="card-body p-4">
          <div class="flex items-start gap-3">
            <%= if @reply.sender do %>
              <.link
                href={~p"/#{@reply.sender.handle || @reply.sender.username}"}
                class="w-10 h-10 flex-shrink-0"
              >
                <.user_avatar user={@reply.sender} size="sm" />
              </.link>

              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2 mb-2 flex-wrap">
                  <div class="inline-flex items-center gap-1">
                    <.link
                      href={~p"/#{@reply.sender.handle || @reply.sender.username}"}
                      class="inline-flex items-center font-medium hover:underline"
                    >
                      <.username_with_effects
                        user={@reply.sender}
                        display_name={true}
                        verified_size="sm"
                      />
                    </.link>
                    <%= if assigns[:post] && @post.sender && @reply.sender_id == @post.sender_id do %>
                      <span class="badge badge-xs badge-info">OP</span>
                    <% end %>
                  </div>
                  <span class="text-sm opacity-70">
                    ·
                    <.local_time
                      datetime={@reply.inserted_at}
                      format="relative"
                      timezone={@timezone}
                      time_format={@time_format}
                    />
                  </span>
                </div>

                <div class="mb-3">
                  <div class="break-words">
                    {raw(make_links_clickable(@reply.content))}
                  </div>
                </div>

                <div class="flex items-center gap-2">
                  <%= if @current_user do %>
                    <button
                      phx-click="like_reply"
                      phx-value-reply_id={@reply.id}
                      class={[
                        "btn btn-ghost btn-sm",
                        Map.get(@liked_replies, @reply.id, false) && "text-red-800"
                      ]}
                    >
                      <.icon
                        name={
                          if Map.get(@liked_replies, @reply.id, false),
                            do: "hero-heart-solid",
                            else: "hero-heart"
                        }
                        class="w-4 h-4 mr-1"
                      />
                      {@reply.like_count || 0}
                    </button>
                    <button
                      phx-click="show_reply_to_reply_form"
                      phx-value-reply_id={@reply.id}
                      class="btn btn-ghost btn-sm"
                    >
                      <.icon name="hero-chat-bubble-left" class="w-4 h-4 mr-1" />
                      {@reply.reply_count || 0}
                    </button>
                  <% else %>
                    <div class="flex items-center gap-2 opacity-70">
                      <.icon name="hero-heart" class="w-4 h-4" />
                      <span class="text-sm">{@reply.like_count || 0}</span>
                    </div>
                    <div class="flex items-center gap-2 opacity-70">
                      <.icon name="hero-chat-bubble-left" class="w-4 h-4" />
                      <span class="text-sm">{@reply.reply_count || 0}</span>
                    </div>
                  <% end %>
                  <button
                    phx-click="copy_reply_link"
                    phx-value-reply_id={@reply.id}
                    class="btn btn-ghost btn-sm"
                  >
                    <.icon name="hero-share" class="w-4 h-4" />
                  </button>
                  <%= if @reply.activitypub_id do %>
                    <a
                      href={@reply.activitypub_id}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="btn btn-ghost btn-sm"
                      title="Open on remote instance"
                    >
                      <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
                    </a>
                  <% end %>
                </div>
              </div>
            <% else %>
              <%!-- Federated reply --%>
              <%= if @reply.remote_actor.avatar_url do %>
                <img
                  src={@reply.remote_actor.avatar_url}
                  alt={@reply.remote_actor.username}
                  class="w-10 h-10 rounded-full flex-shrink-0"
                />
              <% else %>
                <div class="w-10 h-10 rounded-full bg-base-300 flex items-center justify-center flex-shrink-0">
                  <.icon name="hero-user" class="w-6 h-6" />
                </div>
              <% end %>

              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2 mb-2 flex-wrap">
                  <div class="inline-flex items-center gap-1">
                    <div class="font-medium">
                      {raw(
                        render_display_name_with_emojis(
                          @reply.remote_actor.display_name || @reply.remote_actor.username,
                          @reply.remote_actor.domain
                        )
                      )}
                    </div>
                  </div>
                  <span class="text-sm opacity-70">
                    @{@reply.remote_actor.username}@{@reply.remote_actor.domain} ·
                    <.local_time
                      datetime={@reply.inserted_at}
                      format="relative"
                      timezone={@timezone}
                      time_format={@time_format}
                    />
                  </span>
                </div>

                <div class="mb-3">
                  <div class="break-words">
                    {raw(make_links_clickable(@reply.content))}
                  </div>
                </div>

                <div class="flex items-center gap-2">
                  <%= if @current_user do %>
                    <button
                      phx-click="like_reply"
                      phx-value-reply_id={@reply.id}
                      class={[
                        "btn btn-ghost btn-sm",
                        Map.get(@liked_replies, @reply.id, false) && "text-red-800"
                      ]}
                    >
                      <.icon
                        name={
                          if Map.get(@liked_replies, @reply.id, false),
                            do: "hero-heart-solid",
                            else: "hero-heart"
                        }
                        class="w-4 h-4 mr-1"
                      />
                      {@reply.like_count || 0}
                    </button>
                    <button
                      phx-click="show_reply_to_reply_form"
                      phx-value-reply_id={@reply.id}
                      class="btn btn-ghost btn-sm"
                    >
                      <.icon name="hero-chat-bubble-left" class="w-4 h-4 mr-1" />
                      {@reply.reply_count || 0}
                    </button>
                  <% else %>
                    <div class="flex items-center gap-2 opacity-70">
                      <.icon name="hero-heart" class="w-4 h-4" />
                      <span class="text-sm">{@reply.like_count || 0}</span>
                    </div>
                    <div class="flex items-center gap-2 opacity-70">
                      <.icon name="hero-chat-bubble-left" class="w-4 h-4" />
                      <span class="text-sm">{@reply.reply_count || 0}</span>
                    </div>
                  <% end %>
                  <button
                    phx-click="copy_reply_link"
                    phx-value-reply_id={@reply.id}
                    class="btn btn-ghost btn-sm"
                  >
                    <.icon name="hero-share" class="w-4 h-4" />
                  </button>
                  <%= if @reply.activitypub_id do %>
                    <a
                      href={@reply.activitypub_id}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="btn btn-ghost btn-sm"
                      title="Open on remote instance"
                    >
                      <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
                    </a>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%= if @current_user && @reply_to_reply_id == @reply.id do %>
        <div class="mt-3 p-4 bg-base-200 rounded-lg border border-base-300">
          <div class="flex items-start gap-3">
            <div class="w-8 h-8 flex-shrink-0">
              <.user_avatar user={@current_user} size="sm" />
            </div>
            <div class="flex-1 min-w-0">
              <div class="text-sm opacity-70 mb-3">
                <%= if @reply.sender do %>
                  Replying to
                  <span class="font-medium text-error">
                    <.username_with_effects user={@reply.sender} show_at={true} verified_size="xs" />
                  </span>
                <% else %>
                  Replying to
                  <span class="font-medium text-error">
                    @{@reply.remote_actor.username}@{@reply.remote_actor.domain}
                  </span>
                <% end %>
              </div>

              <form phx-submit="create_reply" class="space-y-4">
                <input type="hidden" name="reply_to_id" value={@reply.id} />
                <textarea
                  name="content"
                  placeholder="Post your reply..."
                  class="textarea textarea-bordered w-full"
                  rows="3"
                  value={@reply_content}
                  phx-change="update_reply_content"
                  phx-mounted={JS.focus()}
                  required
                ></textarea>

                <div class="flex gap-2 justify-end items-center">
                  <span class={[
                    "text-xs",
                    String.length(@reply_content || "") < 3 && "text-error",
                    String.length(@reply_content || "") >= 3 && "text-success"
                  ]}>
                    {String.length(@reply_content || "")}/3 min
                  </span>
                  <button type="button" phx-click="cancel_reply_to_reply" class="btn btn-ghost btn-sm">
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="btn btn-secondary btn-sm"
                    phx-disable-with="Posting..."
                    disabled={String.length(@reply_content || "") < 3}
                  >
                    <.icon name="hero-paper-airplane" class="w-4 h-4 mr-1" /> Reply
                  </button>
                </div>
              </form>
            </div>
          </div>
        </div>
      <% end %>

      <%= if Map.has_key?(@reply, :nested_replies) && !Enum.empty?(@reply.nested_replies) && @depth < @max_depth do %>
        <div class="mt-2 space-y-2">
          <%= for nested_reply <- @reply.nested_replies do %>
            <.render_reply
              reply={nested_reply}
              post={@post}
              current_user={@current_user}
              reply_to_reply_id={@reply_to_reply_id}
              reply_content={@reply_content}
              depth={@depth + 1}
              liked_replies={@liked_replies}
              timezone={@timezone}
              time_format={@time_format}
            />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def mount(%{"id" => post_id}, _session, socket) do
    user = socket.assigns[:current_user]
    post_id = String.to_integer(post_id)

    # Get the timeline post with all replies
    case get_timeline_post_with_replies(post_id, user && user.id) do
      {:ok, post, _replies, _total_count} ->
        # Check if post is approved (hide automoderated posts from non-owners)
        is_approved = post.approval_status in ["approved", nil]
        is_owner = user && user.id == post.sender_id

        # Check if post is public or user has access
        can_view =
          case post.visibility do
            "public" ->
              true

            "followers" ->
              user && (user.id == post.sender_id || Social.following?(user.id, post.sender_id))

            "friends" ->
              user &&
                (user.id == post.sender_id ||
                   Elektrine.Friends.are_friends?(user.id, post.sender_id))

            "private" ->
              user && user.id == post.sender_id

            _ ->
              false
          end

        # Don't show unapproved posts to anyone except the owner
        can_view = can_view && (is_approved || is_owner)

        cond do
          can_view ->
            # Keep timeline visibility checks, but render with the canonical post detail view.
            {:ok, redirect(socket, to: ~p"/remote/post/#{post_id}")}

          user ->
            # User is authenticated but doesn't have access
            {:ok,
             socket
             |> put_flash(:error, "You don't have permission to view this post")
             |> push_navigate(to: ~p"/timeline")}

          true ->
            # Redirect unauthenticated users to login for non-public posts
            {:ok, push_navigate(socket, to: ~p"/login")}
        end

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/timeline")}
    end
  end

  @impl true
  def handle_event("navigate_to_origin", %{"url" => url}, socket) do
    {:noreply, push_navigate(socket, to: url)}
  end

  def handle_event("navigate_to_embedded_post", %{"url" => url}, socket) when is_binary(url) do
    {:noreply, push_navigate(socket, to: url)}
  end

  def handle_event("navigate_to_embedded_post", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{id}")}
  end

  def handle_event("navigate_to_remote_post", %{"url" => activitypub_id}, socket)
      when is_binary(activitypub_id) and activitypub_id != "" do
    encoded = URI.encode_www_form(activitypub_id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{encoded}")}
  end

  def handle_event("navigate_to_remote_post", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("stop_event", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("toggle_reply_form", _params, socket) do
    if socket.assigns[:current_user] do
      {:noreply,
       socket
       |> assign(:show_reply_form, !socket.assigns.show_reply_form)
       |> assign(:reply_to_reply_id, nil)}
    else
      {:noreply, push_navigate(socket, to: ~p"/login")}
    end
  end

  def handle_event("copy_post_link", _params, socket) do
    # Generate the current post URL
    post_url = "#{ElektrineWeb.Endpoint.url()}/timeline/post/#{socket.assigns.post.id}"

    {:noreply,
     socket
     |> push_event("copy_to_clipboard", %{text: post_url})
     |> put_flash(:info, "Link copied to clipboard")}
  end

  def handle_event("create_reply", %{"content" => content} = params, socket) do
    if String.trim(content) == "" do
      {:noreply, put_flash(socket, :error, "Reply cannot be empty")}
    else
      # Determine what we're replying to - either a specific reply or the main post
      reply_to_id =
        case Map.get(params, "reply_to_id") do
          nil -> socket.assigns.post.id
          id when is_binary(id) -> String.to_integer(id)
          id -> id
        end

      # Create timeline reply - match parent post visibility or use public
      parent_visibility = socket.assigns.post.visibility || "public"

      case Social.create_timeline_post(
             socket.assigns.current_user.id,
             content,
             visibility: parent_visibility
           ) do
        {:ok, reply_post} ->
          # Link it as a reply
          reply_post
          |> Elektrine.Messaging.Message.changeset(%{reply_to_id: reply_to_id})
          |> Elektrine.Repo.update()

          # Increment reply count on parent
          Social.increment_reply_count(reply_to_id)

          # Create notification for timeline comment/reply
          # Get the original post/reply being replied to
          parent_message = Elektrine.Repo.get!(Elektrine.Messaging.Message, reply_to_id)

          if parent_message.sender_id &&
               parent_message.sender_id != socket.assigns.current_user.id do
            # Check if user wants to be notified about comments
            parent_author = Elektrine.Accounts.get_user!(parent_message.sender_id)

            if Map.get(parent_author, :notify_on_comment, true) do
              Elektrine.Notifications.create_notification(%{
                user_id: parent_message.sender_id,
                actor_id: socket.assigns.current_user.id,
                type: "comment",
                title:
                  "@#{socket.assigns.current_user.handle || socket.assigns.current_user.username} commented on your post",
                body: String.slice(content, 0, 100),
                url: "/timeline/post/#{socket.assigns.post.id}#reply-#{reply_post.id}",
                source_type: "message",
                source_id: reply_post.id,
                priority: "normal"
              })
            end
          end

          # Process mentions in the comment (wrapped in try-rescue to prevent comment failure)
          try do
            mentions =
              Regex.scan(~r/@(\w+)/, content)
              |> Enum.map(fn [_, username] -> username end)
              |> Enum.uniq()

            sender = socket.assigns.current_user

            Enum.each(mentions, fn username ->
              case Elektrine.Accounts.get_user_by_username_or_handle(username) do
                nil ->
                  :ok

                mentioned_user ->
                  if mentioned_user.id != socket.assigns.current_user.id &&
                       mentioned_user.id != parent_message.sender_id do
                    # Check if user wants to be notified about mentions
                    if Map.get(mentioned_user, :notify_on_mention, true) do
                      Elektrine.Notifications.create_notification(%{
                        user_id: mentioned_user.id,
                        actor_id: socket.assigns.current_user.id,
                        type: "mention",
                        title: "@#{sender.handle || sender.username} mentioned you",
                        body: "You were mentioned in a comment",
                        url: "/timeline/post/#{socket.assigns.post.id}#reply-#{reply_post.id}",
                        source_type: "message",
                        source_id: reply_post.id,
                        priority: "normal"
                      })
                    end
                  end
              end
            end)
          rescue
            e ->
              require Logger
              Logger.error("Error processing mentions in timeline comment: #{inspect(e)}")
          end

          # Reload post and replies to get updated count
          {:ok, updated_post, updated_replies, total_count} =
            get_timeline_post_with_replies(socket.assigns.post.id, socket.assigns.current_user.id)

          {:noreply,
           socket
           |> assign(:post, updated_post)
           |> assign(:replies, updated_replies)
           |> assign(:total_reply_count, total_count)
           |> assign(
             :liked_replies,
             get_liked_replies(socket.assigns.current_user.id, updated_replies)
           )
           |> assign(:reply_content, "")
           |> assign(:show_reply_form, false)
           |> assign(:reply_to_reply_id, nil)
           |> put_flash(:info, "Reply posted!")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to post reply")}
      end
    end
  end

  def handle_event("update_reply_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, :reply_content, content)}
  end

  def handle_event("like_post", _params, socket) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id
      message_id = socket.assigns.post.id

      case socket.assigns.liked_by_user do
        true ->
          case Social.unlike_post(user_id, message_id) do
            {:ok, _} ->
              updated_post = %{
                socket.assigns.post
                | like_count: max(0, socket.assigns.post.like_count - 1)
              }

              {:noreply,
               socket
               |> assign(:post, updated_post)
               |> assign(:liked_by_user, false)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to unlike post")}
          end

        false ->
          case Social.like_post(user_id, message_id) do
            {:ok, _} ->
              updated_post = %{
                socket.assigns.post
                | like_count: socket.assigns.post.like_count + 1
              }

              {:noreply,
               socket
               |> assign(:post, updated_post)
               |> assign(:liked_by_user, true)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to like post")}
          end
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/login")}
    end
  end

  # Modal like toggle (for image modal)
  def handle_event("toggle_modal_like", _params, socket) do
    handle_event("like_post", %{}, socket)
  end

  def handle_event("like_reply", %{"reply_id" => reply_id}, socket) do
    if socket.assigns[:current_user] do
      reply_id = String.to_integer(reply_id)
      user_id = socket.assigns.current_user.id
      already_liked = Map.get(socket.assigns.liked_replies, reply_id, false)

      case {already_liked, Social.like_post(user_id, reply_id),
            Social.unlike_post(user_id, reply_id)} do
        {false, {:ok, _}, _} ->
          # Like the reply
          updated_replies =
            update_reply_in_tree(socket.assigns.replies, reply_id, fn r ->
              %{r | like_count: (r.like_count || 0) + 1}
            end)

          {:noreply,
           socket
           |> assign(:replies, updated_replies)
           |> assign(:liked_replies, Map.put(socket.assigns.liked_replies, reply_id, true))}

        {true, _, {:ok, _}} ->
          # Unlike the reply
          updated_replies =
            update_reply_in_tree(socket.assigns.replies, reply_id, fn r ->
              %{r | like_count: max(0, (r.like_count || 0) - 1)}
            end)

          {:noreply,
           socket
           |> assign(:replies, updated_replies)
           |> assign(:liked_replies, Map.put(socket.assigns.liked_replies, reply_id, false))}

        _ ->
          {:noreply, put_flash(socket, :error, "Failed to update like")}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/login")}
    end
  end

  def handle_event("show_reply_to_reply_form", %{"reply_id" => reply_id} = _params, socket) do
    reply_id = String.to_integer(reply_id)

    {:noreply,
     socket
     |> assign(:reply_to_reply_id, reply_id)
     |> assign(:reply_content, "")
     |> assign(:show_reply_form, false)}
  end

  def handle_event("cancel_reply_to_reply", _params, socket) do
    {:noreply,
     socket
     |> assign(:reply_to_reply_id, nil)
     |> assign(:reply_content, "")}
  end

  def handle_event("open_external_link", %{"url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, redirect(socket, external: url)}
  end

  def handle_event("open_external_link", _params, socket) do
    # URL is nil or empty - fallback to doing nothing
    {:noreply, socket}
  end

  def handle_event("copy_reply_link", %{"reply_id" => reply_id}, socket) do
    reply_url =
      "#{ElektrineWeb.Endpoint.url()}/timeline/post/#{socket.assigns.post.id}#reply-#{reply_id}"

    {:noreply,
     socket
     |> push_event("copy_to_clipboard", %{text: reply_url})
     |> put_flash(:info, "Link copied to clipboard")}
  end

  def handle_event(
        "open_image_modal",
        %{"url" => url, "images" => images_json, "index" => index, "post_id" => post_id},
        socket
      ) do
    # Decode the JSON array of image URLs
    images = Jason.decode!(images_json)

    # Use the current post if the post_id matches
    modal_post =
      if socket.assigns.post.id == String.to_integer(post_id) do
        socket.assigns.post
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:show_image_modal, true)
     |> assign(:modal_image_url, url)
     |> assign(:modal_images, images)
     |> assign(:modal_image_index, String.to_integer(index))
     |> assign(:modal_post, modal_post)}
  end

  def handle_event("close_image_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_image_modal, false)
     |> assign(:modal_image_url, nil)
     |> assign(:modal_images, [])
     |> assign(:modal_image_index, 0)
     |> assign(:modal_post, nil)}
  end

  def handle_event("next_image", _params, socket) do
    new_index = rem(socket.assigns.modal_image_index + 1, length(socket.assigns.modal_images))
    new_url = Enum.at(socket.assigns.modal_images, new_index)

    {:noreply,
     socket
     |> assign(:modal_image_index, new_index)
     |> assign(:modal_image_url, new_url)}
  end

  def handle_event("prev_image", _params, socket) do
    new_index =
      if socket.assigns.modal_image_index == 0 do
        length(socket.assigns.modal_images) - 1
      else
        socket.assigns.modal_image_index - 1
      end

    new_url = Enum.at(socket.assigns.modal_images, new_index)

    {:noreply,
     socket
     |> assign(:modal_image_index, new_index)
     |> assign(:modal_image_url, new_url)}
  end

  def handle_event("navigate_to_profile", %{"handle" => handle}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/#{handle}")}
  end

  def handle_event("react_to_post", %{"post_id" => post_id, "emoji" => emoji}, socket) do
    if socket.assigns.current_user do
      user_id = socket.assigns.current_user.id
      message_id = String.to_integer(post_id)

      alias Elektrine.Messaging.Reactions

      # Check if user already has this reaction
      existing_reaction =
        Elektrine.Repo.get_by(
          Elektrine.Messaging.MessageReaction,
          message_id: message_id,
          user_id: user_id,
          emoji: emoji
        )

      if existing_reaction do
        # Remove the existing reaction
        case Reactions.remove_reaction(message_id, user_id, emoji) do
          {:ok, _} ->
            updated_reactions =
              update_post_reactions(
                socket,
                message_id,
                %{emoji: emoji, user_id: user_id},
                :remove
              )

            {:noreply, assign(socket, :post_reactions, updated_reactions)}

          {:error, _} ->
            {:noreply, socket}
        end
      else
        # Add new reaction
        case Reactions.add_reaction(message_id, user_id, emoji) do
          {:ok, reaction} ->
            reaction = Elektrine.Repo.preload(reaction, [:user, :remote_actor])
            updated_reactions = update_post_reactions(socket, message_id, reaction, :add)
            {:noreply, assign(socket, :post_reactions, updated_reactions)}

          {:error, :rate_limited} ->
            {:noreply, put_flash(socket, :error, "Slow down! You're reacting too fast")}

          {:error, _} ->
            {:noreply, socket}
        end
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/login")}
    end
  end

  def handle_event(
        "discuss_privately",
        %{"message_id" => _message_id, "target_user_id" => target_user_id},
        socket
      ) do
    target_user_id = String.to_integer(target_user_id)

    case Elektrine.Messaging.create_dm_conversation(
           socket.assigns.current_user.id,
           target_user_id
         ) do
      {:ok, dm_conversation} ->
        {:noreply,
         socket
         |> push_navigate(to: ~p"/chat/#{dm_conversation.hash || dm_conversation.id}")}

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You are creating too many conversations. Please wait a moment and try again."
         )}

      {:error, reason} ->
        error_message = Elektrine.Privacy.privacy_error_message(reason)
        {:noreply, put_flash(socket, :error, error_message)}
    end
  end

  # Quote post handlers
  def handle_event("quote_post", %{"post_id" => post_id}, socket) do
    handle_event("quote_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("quote_post", %{"message_id" => _message_id}, socket) do
    if socket.assigns[:current_user] do
      post = socket.assigns.post

      {:noreply,
       socket
       |> assign(:quote_target_post, post)
       |> assign(:show_quote_modal, true)
       |> assign(:quote_content, "")}
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to quote posts")}
    end
  end

  def handle_event("close_quote_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_quote_modal, false)
     |> assign(:quote_target_post, nil)
     |> assign(:quote_content, "")}
  end

  def handle_event("update_quote_content", params, socket) do
    content = params["content"] || params["value"] || ""
    {:noreply, assign(socket, :quote_content, content)}
  end

  def handle_event("submit_quote", params, socket) do
    content = params["content"] || params["value"] || socket.assigns.quote_content || ""

    if socket.assigns[:current_user] do
      user = socket.assigns.current_user
      quote_target = socket.assigns.quote_target_post

      if quote_target && String.trim(content) != "" do
        case Social.create_quote_post(user.id, quote_target.id, content) do
          {:ok, _quote_post} ->
            {:noreply,
             socket
             |> assign(:show_quote_modal, false)
             |> assign(:quote_target_post, nil)
             |> assign(:quote_content, "")
             |> put_flash(:info, "Quote posted!")}

          {:error, :empty_quote} ->
            {:noreply, put_flash(socket, :error, "Quote content cannot be empty")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to create quote")}
        end
      else
        {:noreply, put_flash(socket, :error, "Please add some content to your quote")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to quote posts")}
    end
  end

  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
  end

  # Helper functions

  defp update_post_reactions(socket, message_id, reaction, action) do
    current_reactions = Map.get(socket.assigns, :post_reactions, %{})
    post_reactions = Map.get(current_reactions, message_id, [])

    updated =
      case action do
        :add ->
          if Enum.any?(post_reactions, fn r ->
               r.emoji == reaction.emoji && r.user_id == reaction.user_id
             end) do
            post_reactions
          else
            [reaction | post_reactions]
          end

        :remove ->
          Enum.reject(post_reactions, fn r ->
            r.emoji == reaction.emoji && r.user_id == reaction.user_id
          end)
      end

    Map.put(current_reactions, message_id, updated)
  end

  defp get_timeline_post_with_replies(post_id, _user_id) do
    import Ecto.Query
    post_preloads = MessagingMessages.timeline_post_preloads()
    reply_preloads = MessagingMessages.timeline_reply_preloads()

    # Get the main timeline post
    post =
      from(m in Elektrine.Messaging.Message,
        where:
          m.id == ^post_id and
            is_nil(m.deleted_at) and
            (is_nil(m.post_type) or m.post_type in ["post", "gallery", "link", "poll"]),
        preload: ^post_preloads
      )
      |> Elektrine.Repo.one()

    # Force reload remote_actor if post is federated
    post =
      if post && post.federated && post.remote_actor_id do
        Elektrine.Repo.preload(post, [:remote_actor], force: true)
      else
        post
      end

    case post do
      nil ->
        {:error, :not_found}

      post ->
        # Get all nested replies (replies to replies, recursively)
        all_reply_ids = get_all_nested_replies(post_id)

        # Load all replies with associations
        all_replies =
          if Enum.empty?(all_reply_ids) do
            []
          else
            from(m in Elektrine.Messaging.Message,
              where:
                m.id in ^all_reply_ids and
                  is_nil(m.deleted_at) and
                  (m.approval_status == "approved" or is_nil(m.approval_status)),
              order_by: [asc: m.inserted_at],
              preload: ^reply_preloads
            )
            |> Elektrine.Repo.all()
          end

        # Build nested structure
        replies = build_reply_tree(all_replies, post_id)

        # Count total including nested
        total_count = count_all_replies(replies)

        {:ok, post, replies, total_count}
    end
  end

  # Get all nested replies recursively
  defp get_all_nested_replies(post_id, visited \\ MapSet.new()) do
    import Ecto.Query

    # Get direct replies to this post
    direct_reply_ids =
      from(m in Elektrine.Messaging.Message,
        where: m.reply_to_id == ^post_id and is_nil(m.deleted_at),
        select: m.id
      )
      |> Elektrine.Repo.all()

    # Add to visited set to avoid cycles
    visited = MapSet.put(visited, post_id)

    # Recursively get replies to each direct reply
    nested_reply_ids =
      direct_reply_ids
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.flat_map(fn reply_id ->
        get_all_nested_replies(reply_id, visited)
      end)

    # Return all reply IDs (direct + nested)
    Enum.uniq(direct_reply_ids ++ nested_reply_ids)
  end

  # Build a nested reply tree structure
  defp build_reply_tree(all_replies, parent_id) do
    # Get direct children of this parent
    direct_children = Enum.filter(all_replies, &(&1.reply_to_id == parent_id))

    # For each child, recursively get its children and attach as :nested_replies
    Enum.map(direct_children, fn reply ->
      nested = build_reply_tree(all_replies, reply.id)
      # Count nested replies recursively
      nested_count =
        Enum.reduce(nested, 0, fn r, acc ->
          acc + 1 + (Map.get(r, :nested_reply_count) || 0)
        end)

      reply
      |> Map.put(:nested_replies, nested)
      |> Map.put(:nested_reply_count, nested_count)
    end)
  end

  # Get all reply IDs from nested tree (for checking likes)
  defp get_all_reply_ids_from_tree(replies) do
    Enum.flat_map(replies, fn reply ->
      nested_ids =
        if Map.has_key?(reply, :nested_replies) do
          get_all_reply_ids_from_tree(reply.nested_replies)
        else
          []
        end

      [reply.id | nested_ids]
    end)
  end

  # Get which replies the user has liked
  defp get_liked_replies(user_id, replies) do
    reply_ids = get_all_reply_ids_from_tree(replies)

    if Enum.empty?(reply_ids) do
      %{}
    else
      # Check which ones user has liked
      Enum.reduce(reply_ids, %{}, fn reply_id, acc ->
        liked = Social.user_liked_post?(user_id, reply_id)
        Map.put(acc, reply_id, liked)
      end)
    end
  end

  # Update a reply anywhere in the nested tree
  defp update_reply_in_tree(replies, target_id, update_fn) do
    Enum.map(replies, fn reply ->
      cond do
        reply.id == target_id ->
          update_fn.(reply)

        Map.has_key?(reply, :nested_replies) ->
          %{
            reply
            | nested_replies: update_reply_in_tree(reply.nested_replies, target_id, update_fn)
          }

        true ->
          reply
      end
    end)
  end

  # Count all replies including nested
  defp count_all_replies(replies) do
    Enum.reduce(replies, 0, fn reply, acc ->
      nested_count =
        if Map.has_key?(reply, :nested_replies) do
          count_all_replies(reply.nested_replies)
        else
          0
        end

      acc + 1 + nested_count
    end)
  end

  # Delegate to centralized safe helper to prevent XSS with line break preservation
  defp make_links_clickable(text) do
    text
    |> make_content_safe_with_links()
    |> render_custom_emojis()
    |> preserve_line_breaks()
  end

  @impl true
  def handle_info({:liked, like}, socket) do
    # Skip if this is the current user (already updated optimistically)
    if socket.assigns[:current_user] && like.user_id == socket.assigns.current_user.id do
      {:noreply, socket}
    else
      # Update like count for likes from other users
      if like.message_id == socket.assigns.post.id do
        updated_post = %{
          socket.assigns.post
          | like_count: (socket.assigns.post.like_count || 0) + 1
        }

        {:noreply, assign(socket, :post, updated_post)}
      else
        # Update reply like counts if needed
        updated_replies =
          Enum.map(socket.assigns.replies, fn reply ->
            if reply.id == like.message_id do
              %{reply | like_count: (reply.like_count || 0) + 1}
            else
              reply
            end
          end)

        {:noreply, assign(socket, :replies, updated_replies)}
      end
    end
  end

  @impl true
  def handle_info({:unliked, like}, socket) do
    # Skip if this is the current user (already updated optimistically)
    if socket.assigns[:current_user] && like.user_id == socket.assigns.current_user.id do
      {:noreply, socket}
    else
      # Update like count for unlikes from other users
      if like.message_id == socket.assigns.post.id do
        updated_post = %{
          socket.assigns.post
          | like_count: max((socket.assigns.post.like_count || 1) - 1, 0)
        }

        {:noreply, assign(socket, :post, updated_post)}
      else
        # Update reply like counts if needed
        updated_replies =
          Enum.map(socket.assigns.replies, fn reply ->
            if reply.id == like.message_id do
              %{reply | like_count: max((reply.like_count || 1) - 1, 0)}
            else
              reply
            end
          end)

        {:noreply, assign(socket, :replies, updated_replies)}
      end
    end
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    # Handle new replies to this post in real-time
    if message.reply_to_id == socket.assigns.post.id do
      message_with_associations = Elektrine.Repo.preload(message, [:sender, :conversation])
      updated_replies = [message_with_associations | socket.assigns.replies]

      # Update the reply count on the main post
      updated_post = %{socket.assigns.post | reply_count: length(updated_replies)}

      {:noreply,
       socket
       |> assign(:replies, updated_replies)
       |> assign(:post, updated_post)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:reply_count_updated, message_id, new_count}, socket) do
    # Update the reply count when it changes
    if message_id == socket.assigns.post.id do
      updated_post = %{socket.assigns.post | reply_count: new_count}
      {:noreply, assign(socket, :post, updated_post)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:post_counts_updated, %{message_id: message_id, counts: counts}}, socket) do
    # Update the post counts in real-time
    if message_id == socket.assigns.post.id do
      updated_post = %{
        socket.assigns.post
        | like_count: counts.like_count,
          share_count: counts.share_count,
          reply_count: counts.reply_count
      }

      {:noreply, assign(socket, :post, updated_post)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket) do
    # Catch-all for unhandled messages (like presence_diff broadcasts)
    {:noreply, socket}
  end
end
