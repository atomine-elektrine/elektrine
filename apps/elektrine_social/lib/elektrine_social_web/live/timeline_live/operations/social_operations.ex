defmodule ElektrineSocialWeb.TimelineLive.Operations.SocialOperations do
  @moduledoc "Social operations for timeline interactions including following users,\npreviewing remote users, and managing private discussions.\n"
  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers
  use Phoenix.VerifiedRoutes, endpoint: ElektrineWeb.Endpoint, router: ElektrineWeb.Router
  require Logger
  alias Elektrine.ActivityPub
  alias Elektrine.Profiles
  alias Elektrine.RSS
  alias Elektrine.Social
  alias ElektrineSocialWeb.TimelineLive.Operations.Helpers

  @starter_rss_feeds [
    "https://hnrss.org/frontpage",
    "https://www.theverge.com/rss/index.xml",
    "https://feeds.arstechnica.com/arstechnica/index"
  ]

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
        {:ok, :unfollowed} ->
          updated_posts = Enum.reject(socket.assigns.timeline_posts, &(&1.sender_id == user_id))
          updated_follows = Map.delete(socket.assigns.user_follows, {:local, user_id})

          {:noreply,
           socket
           |> assign(:user_follows, updated_follows)
           |> assign(:timeline_posts, updated_posts)
           |> Helpers.apply_timeline_filter()
           |> put_flash(:info, "Unfollowed user.")}

        {:ok, :not_following} ->
          updated_posts = Enum.reject(socket.assigns.timeline_posts, &(&1.sender_id == user_id))
          updated_follows = Map.delete(socket.assigns.user_follows, {:local, user_id})

          {:noreply,
           socket
           |> assign(:user_follows, updated_follows)
           |> assign(:timeline_posts, updated_posts)
           |> Helpers.apply_timeline_filter()
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
            |> Helpers.refresh_posts_for_sender(user_id)
            |> put_flash(:info, "Now following user.")

          send(self(), {:load_followed_user_posts, user_id})
          {:noreply, updated_socket}

        {:error, _} ->
          {:noreply,
           put_flash(socket, :error, "Couldn't follow this user right now. Please try again.")}
      end
    end
  end

  def handle_event("follow_suggested_people", _params, socket) do
    if socket.assigns[:current_user] do
      current_user_id = socket.assigns.current_user.id

      suggestions =
        socket.assigns.suggested_follows
        |> Enum.reject(fn suggestion ->
          Map.get(socket.assigns.user_follows, {:local, suggestion.id}, false)
        end)
        |> Enum.take(3)

      case suggestions do
        [] ->
          {:noreply, put_flash(socket, :info, "No fresh people to follow right now")}

        _ ->
          {followed_ids, failed_ids} =
            Enum.reduce(suggestions, {[], []}, fn suggestion, {followed, failed} ->
              case Profiles.follow_user(current_user_id, suggestion.id) do
                {:ok, _} -> {[suggestion.id | followed], failed}
                _ -> {followed, [suggestion.id | failed]}
              end
            end)

          updated_socket =
            Enum.reduce(followed_ids, socket, fn user_id, acc ->
              send(self(), {:load_followed_user_posts, user_id})

              assign(
                acc,
                :user_follows,
                Map.put(acc.assigns.user_follows, {:local, user_id}, true)
              )
            end)

          updated_suggestions =
            Enum.reject(updated_socket.assigns.suggested_follows, &(&1.id in followed_ids))

          message =
            cond do
              followed_ids == [] -> "Couldn't follow suggestions right now"
              failed_ids == [] -> "Following #{length(followed_ids)} suggested people"
              true -> "Following #{length(followed_ids)} suggested people"
            end

          {:noreply,
           updated_socket
           |> assign(:suggested_follows, updated_suggestions)
           |> put_flash(:info, message)}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to follow users")}
    end
  end

  def handle_event("preview_remote_user", %{"remote_handle" => remote_handle}, socket) do
    if Elektrine.Strings.present?(remote_handle) do
      socket = assign(socket, remote_user_loading: true, remote_user_preview: nil)

      case parse_and_fetch_remote_user(remote_handle) do
        {:ok, actor} -> send(self(), {:remote_user_fetched, actor})
        {:error, _reason} -> send(self(), {:remote_user_fetch_failed, remote_handle})
      end

      {:noreply, socket}
    else
      {:noreply, assign(socket, remote_user_preview: nil, remote_user_loading: false)}
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

  def handle_event("import_starter_rss_feeds", _params, socket) do
    if socket.assigns[:current_user] do
      current_user_id = socket.assigns.current_user.id

      {imported_count, existing_count} =
        Enum.reduce(@starter_rss_feeds, {0, 0}, fn url, {imported, existing} ->
          case RSS.subscribe(current_user_id, url) do
            {:ok, subscription} ->
              %{feed_id: subscription.feed_id}
              |> Elektrine.RSS.FetchFeedWorker.new()
              |> Elektrine.JobQueue.insert()

              {imported + 1, existing}

            {:error, changeset} ->
              case changeset.errors[:feed_id] do
                {_, constraint: :unique, constraint_name: _} -> {imported, existing + 1}
                _ -> {imported, existing}
              end
          end
        end)

      message =
        cond do
          imported_count > 0 ->
            "Imported #{imported_count} starter RSS feed#{if imported_count == 1, do: "", else: "s"}"

          existing_count > 0 ->
            "Starter RSS feeds are already in your subscriptions"

          true ->
            "Couldn't import starter RSS feeds right now"
        end

      updated_socket =
        if imported_count > 0 do
          send(self(), :load_timeline_data)
          assign(socket, :loading_timeline, true)
        else
          socket
        end

      {:noreply, put_flash(updated_socket, :info, message)}
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to import RSS feeds")}
    end
  end

  def handle_event("toggle_follow_remote", %{"remote_actor_id" => remote_actor_id}, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      remote_actor_id = String.to_integer(remote_actor_id)

      currently_following =
        remote_follow_state(socket.assigns.user_follows, remote_actor_id)

      is_pending = remote_follow_state(socket.assigns.pending_follows, remote_actor_id)

      if currently_following || is_pending do
        case Profiles.unfollow_remote_actor(current_user.id, remote_actor_id) do
          {:ok, :unfollowed} ->
            updated_follows =
              clear_remote_follow_state(socket.assigns.user_follows, remote_actor_id)

            updated_pending =
              clear_remote_follow_state(socket.assigns.pending_follows, remote_actor_id)

            {:noreply,
             socket
             |> assign(:user_follows, updated_follows)
             |> assign(:pending_follows, updated_pending)
             |> Helpers.put_remote_follow_override(remote_actor_id, :none)
             |> Helpers.push_remote_follow_state(remote_actor_id, :none)
             |> put_flash(:info, "Unfollowed")}

          {:error, reason} ->
            Logger.error("Failed to unfollow remote actor: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, "Failed to unfollow user")}
        end
      else
        socket =
          socket
          |> assign(
            :user_follows,
            clear_remote_follow_state(socket.assigns.user_follows, remote_actor_id)
          )
          |> assign(
            :pending_follows,
            put_remote_follow_state(socket.assigns.pending_follows, remote_actor_id, true)
          )

        case Profiles.follow_remote_actor(current_user.id, remote_actor_id) do
          {:ok, follow} ->
            if follow.pending do
              {:noreply,
               socket
               |> Helpers.put_remote_follow_override(remote_actor_id, :pending)
               |> Helpers.push_remote_follow_state(remote_actor_id, :pending)
               |> put_flash(:info, "Follow request sent!")}
            else
              updated_follows =
                put_remote_follow_state(socket.assigns.user_follows, remote_actor_id, true)

              updated_pending =
                clear_remote_follow_state(socket.assigns.pending_follows, remote_actor_id)

              {:noreply,
               socket
               |> assign(:user_follows, updated_follows)
               |> assign(:pending_follows, updated_pending)
               |> Helpers.put_remote_follow_override(remote_actor_id, :following)
               |> Helpers.push_remote_follow_state(remote_actor_id, :following)
               |> put_flash(:info, "Following!")}
            end

          {:error, :already_following} ->
            follow = Profiles.get_follow_to_remote_actor(current_user.id, remote_actor_id)

            if follow && follow.pending do
              {:noreply,
               socket
               |> assign(
                 :pending_follows,
                 put_remote_follow_state(socket.assigns.pending_follows, remote_actor_id, true)
               )
               |> assign(
                 :user_follows,
                 clear_remote_follow_state(socket.assigns.user_follows, remote_actor_id)
               )
               |> Helpers.put_remote_follow_override(remote_actor_id, :pending)
               |> Helpers.push_remote_follow_state(remote_actor_id, :pending)
               |> put_flash(:info, "Follow request already sent")}
            else
              updated_follows =
                put_remote_follow_state(socket.assigns.user_follows, remote_actor_id, true)

              updated_pending =
                clear_remote_follow_state(socket.assigns.pending_follows, remote_actor_id)

              {:noreply,
               socket
               |> assign(:user_follows, updated_follows)
               |> assign(:pending_follows, updated_pending)
               |> Helpers.put_remote_follow_override(remote_actor_id, :following)
               |> Helpers.push_remote_follow_state(remote_actor_id, :following)
               |> put_flash(:info, "Already following this user")}
            end

          {:error, reason} ->
            reverted_pending =
              clear_remote_follow_state(socket.assigns.pending_follows, remote_actor_id)

            Logger.error("Failed to follow remote actor #{remote_actor_id}: #{inspect(reason)}")

            {:noreply,
             socket
             |> assign(:pending_follows, reverted_pending)
             |> Helpers.put_remote_follow_override(remote_actor_id, :none)
             |> Helpers.push_remote_follow_state(remote_actor_id, :none)
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
        {:noreply, socket |> push_navigate(to: Elektrine.Paths.chat_path(dm_conversation))}

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

  defp remote_follow_state(follow_map, remote_actor_id) when is_map(follow_map) do
    Map.get(follow_map, {:remote, remote_actor_id}, false) ||
      Map.get(follow_map, remote_actor_id, false)
  end

  defp remote_follow_state(_, _), do: false

  defp put_remote_follow_state(follow_map, remote_actor_id, value) when is_map(follow_map) do
    follow_map
    |> Map.put({:remote, remote_actor_id}, value)
    |> Map.put(remote_actor_id, value)
  end

  defp put_remote_follow_state(_, remote_actor_id, value) do
    put_remote_follow_state(%{}, remote_actor_id, value)
  end

  defp clear_remote_follow_state(follow_map, remote_actor_id) when is_map(follow_map) do
    follow_map
    |> Map.delete({:remote, remote_actor_id})
    |> Map.delete(remote_actor_id)
  end

  defp clear_remote_follow_state(_, _), do: %{}

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
