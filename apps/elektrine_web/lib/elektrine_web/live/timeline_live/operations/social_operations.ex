defmodule ElektrineWeb.TimelineLive.Operations.SocialOperations do
  @moduledoc "Social operations for timeline interactions including following users,\npreviewing remote users, and managing private discussions.\n"
  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers
  use Phoenix.VerifiedRoutes, endpoint: ElektrineWeb.Endpoint, router: ElektrineWeb.Router
  require Logger
  alias Elektrine.ActivityPub
  alias Elektrine.Profiles
  alias Elektrine.Social
  alias ElektrineWeb.TimelineLive.Operations.Helpers

  def handle_event("follow_suggested_user", %{"user_id" => user_id}, socket) do
    if socket.assigns[:current_user] do
      current_user_id = socket.assigns.current_user.id
      user_id = String.to_integer(user_id)

      case Social.follow_user(current_user_id, user_id) do
        {:ok, _follow} ->
          updated_suggestions = Enum.reject(socket.assigns.suggested_follows, &(&1.id == user_id))
          updated_user_follows = Map.put(socket.assigns.user_follows, {:local, user_id}, true)

          new_user_posts =
            Social.get_user_timeline_posts(user_id,
              limit: 20,
              viewer_id: socket.assigns.current_user.id
            )

          updated_posts =
            Helpers.merge_and_sort_posts(socket.assigns.timeline_posts, new_user_posts)

          updated_user_likes =
            Map.merge(
              socket.assigns.user_likes,
              Helpers.get_user_likes(current_user_id, new_user_posts)
            )

          {:noreply,
           socket
           |> assign(:suggested_follows, updated_suggestions)
           |> assign(:user_follows, updated_user_follows)
           |> assign(:timeline_posts, updated_posts)
           |> assign(:user_likes, updated_user_likes)
           |> Helpers.apply_timeline_filter()
           |> put_flash(:info, "Following user. Recent posts were added to your timeline.")}

        {:error, _} ->
          {:noreply,
           put_flash(socket, :error, "Couldn't follow this user right now. Please try again.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to follow users")}
    end
  end

  def handle_event("refresh_suggestions", _params, socket) do
    if socket.assigns[:current_user] do
      new_suggestions = Social.get_suggested_follows(socket.assigns.current_user.id, limit: 5)

      {:noreply,
       socket
       |> assign(:suggested_follows, new_suggestions)
       |> put_flash(:info, "Suggestions refreshed!")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_follow", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)
    current_user_id = socket.assigns.current_user.id
    currently_following = Map.get(socket.assigns.user_follows, {:local, user_id}, false)

    if currently_following do
      case Profiles.unfollow_user(current_user_id, user_id) do
        {1, _} ->
          updated_posts = Enum.reject(socket.assigns.timeline_posts, &(&1.sender_id == user_id))
          updated_follows = Map.delete(socket.assigns.user_follows, {:local, user_id})

          {:noreply,
           socket
           |> assign(:user_follows, updated_follows)
           |> assign(:timeline_posts, updated_posts)
           |> put_flash(:info, "Unfollowed user.")}

        _ ->
          {:noreply, put_flash(socket, :error, "Couldn't unfollow right now. Please try again.")}
      end
    else
      case Profiles.follow_user(current_user_id, user_id) do
        {:ok, _} ->
          updated_suggestions = Enum.reject(socket.assigns.suggested_follows, &(&1.id == user_id))
          updated_follows = Map.put(socket.assigns.user_follows, {:local, user_id}, true)

          updated_socket =
            socket
            |> assign(:user_follows, updated_follows)
            |> assign(:suggested_follows, updated_suggestions)
            |> put_flash(:info, "Now following user.")

          send(self(), {:load_followed_user_posts, user_id})
          {:noreply, updated_socket}

        {:error, _} ->
          {:noreply,
           put_flash(socket, :error, "Couldn't follow this user right now. Please try again.")}
      end
    end
  end

  def handle_event("preview_remote_user", %{"remote_handle" => remote_handle}, socket) do
    if String.trim(remote_handle) == "" do
      {:noreply, assign(socket, remote_user_preview: nil, remote_user_loading: false)}
    else
      socket = assign(socket, remote_user_loading: true, remote_user_preview: nil)
      lv_pid = self()

      Task.start(fn ->
        case parse_and_fetch_remote_user(remote_handle) do
          {:ok, actor} -> send(lv_pid, {:remote_user_fetched, actor})
          {:error, _reason} -> send(lv_pid, {:remote_user_fetch_failed, remote_handle})
        end
      end)

      {:noreply, socket}
    end
  end

  def handle_event("follow_remote_user", %{"remote_handle" => _remote_handle}, socket) do
    if socket.assigns.remote_user_preview do
      actor = socket.assigns.remote_user_preview
      current_user = socket.assigns.current_user

      case Profiles.follow_remote_actor(current_user.id, actor.id) do
        {:ok, _follow} ->
          actor_type =
            if actor.actor_type == "Group" do
              "community"
            else
              "user"
            end

          handle_prefix =
            if actor.actor_type == "Group" do
              "!"
            else
              "@"
            end

          {:noreply,
           socket
           |> assign(:remote_user_preview, nil)
           |> notify_info(
             "Following #{actor_type} #{handle_prefix}#{actor.username}@#{actor.domain}!"
           )}

        {:error, :already_following} ->
          {:noreply,
           notify_info(
             socket,
             "You're already following this #{if actor.actor_type == "Group" do
               "community"
             else
               "user"
             end}"
           )}

        {:error, reason} ->
          Logger.error("Failed to follow remote actor: #{inspect(reason)}")
          {:noreply, notify_error(socket, "Failed to follow")}
      end
    else
      {:noreply, notify_error(socket, "Please search for a user or community first")}
    end
  end

  def handle_event("toggle_follow_remote", %{"remote_actor_id" => remote_actor_id}, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      remote_actor_id = String.to_integer(remote_actor_id)

      currently_following =
        Map.get(socket.assigns.user_follows, {:remote, remote_actor_id}, false)

      is_pending = Map.get(socket.assigns.pending_follows, {:remote, remote_actor_id}, false)

      if currently_following || is_pending do
        case Profiles.unfollow_remote_actor(current_user.id, remote_actor_id) do
          {:ok, :unfollowed} ->
            updated_follows = Map.delete(socket.assigns.user_follows, {:remote, remote_actor_id})

            updated_pending =
              Map.delete(socket.assigns.pending_follows, {:remote, remote_actor_id})

            {:noreply,
             socket
             |> assign(:user_follows, updated_follows)
             |> assign(:pending_follows, updated_pending)
             |> put_flash(:info, "Unfollowed")}

          {:error, reason} ->
            Logger.error("Failed to unfollow remote actor: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, "Failed to unfollow user")}
        end
      else
        optimistic_pending =
          Map.put(socket.assigns.pending_follows, {:remote, remote_actor_id}, true)

        socket = assign(socket, :pending_follows, optimistic_pending)

        case Profiles.follow_remote_actor(current_user.id, remote_actor_id) do
          {:ok, follow} ->
            if follow.pending do
              {:noreply, put_flash(socket, :info, "Follow request sent!")}
            else
              updated_follows =
                Map.put(socket.assigns.user_follows, {:remote, remote_actor_id}, true)

              updated_pending =
                Map.delete(socket.assigns.pending_follows, {:remote, remote_actor_id})

              {:noreply,
               socket
               |> assign(:user_follows, updated_follows)
               |> assign(:pending_follows, updated_pending)
               |> put_flash(:info, "Following!")}
            end

          {:error, :already_following} ->
            follow = Profiles.get_follow_to_remote_actor(current_user.id, remote_actor_id)

            if follow && follow.pending do
              {:noreply, put_flash(socket, :info, "Follow request already sent")}
            else
              updated_follows =
                Map.put(socket.assigns.user_follows, {:remote, remote_actor_id}, true)

              updated_pending =
                Map.delete(socket.assigns.pending_follows, {:remote, remote_actor_id})

              {:noreply,
               socket
               |> assign(:user_follows, updated_follows)
               |> assign(:pending_follows, updated_pending)
               |> put_flash(:info, "Already following this user")}
            end

          {:error, reason} ->
            reverted_pending =
              Map.delete(socket.assigns.pending_follows, {:remote, remote_actor_id})

            Logger.error("Failed to follow remote actor #{remote_actor_id}: #{inspect(reason)}")

            {:noreply,
             socket
             |> assign(:pending_follows, reverted_pending)
             |> put_flash(:error, "Failed to follow user")}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to follow users")}
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
         socket |> push_navigate(to: ~p"/chat/#{dm_conversation.hash || dm_conversation.id}")}

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

  defp parse_and_fetch_remote_user(remote_handle) do
    handle =
      remote_handle |> String.trim_leading("@") |> String.trim_leading("!") |> String.trim()

    case String.split(handle, "@") do
      [username, domain] when username != "" and domain != "" ->
        acct = "#{username}@#{domain}"

        case ActivityPub.Fetcher.webfinger_lookup(acct) do
          {:ok, actor_uri} ->
            ActivityPub.get_or_fetch_actor(actor_uri)

          {:error, _} ->
            case ActivityPub.Fetcher.webfinger_lookup("!#{acct}") do
              {:ok, actor_uri} -> ActivityPub.get_or_fetch_actor(actor_uri)
              error -> error
            end
        end

      _ ->
        {:error, :invalid_handle}
    end
  end
end
