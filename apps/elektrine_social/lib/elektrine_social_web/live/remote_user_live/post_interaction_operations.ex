defmodule ElektrineSocialWeb.RemoteUserLive.PostInteractionOperations do
  @moduledoc """
  Post interaction events for the remote user profile LiveView: like/unlike,
  up/downvotes, boosts, quotes, poll votes, reactions, and saves.

  Each `handle_event/3` clause mirrors the LiveView callback and returns a
  `{:noreply, socket}` tuple.
  """

  import Phoenix.Component
  import Phoenix.LiveView, only: [put_flash: 3]
  import ElektrineSocialWeb.RemoteUserLive.PostState

  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Messages, as: MessagingMessages
  alias Elektrine.Social.Votes
  alias ElektrineWeb.Live.PostInteractions

  def handle_event("like_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    else
      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          case Elektrine.Social.like_post(socket.assigns.current_user.id, message.id) do
            {:ok, _like} ->
              key = PostInteractions.interaction_key(post_id, message)

              # Update interaction state and increment count
              current_state =
                socket.assigns.post_interactions[key] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, key, %{
                  liked: true,
                  boosted: Map.get(current_state, :boosted, false),
                  like_delta: Map.get(current_state, :like_delta, 0) + 1,
                  boost_delta: Map.get(current_state, :boost_delta, 0)
                })

              {:noreply, assign(socket, :post_interactions, post_interactions)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to like post")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process remote post")}
      end
    end
  end

  def handle_event("like_post", %{"message_id" => message_id}, socket) do
    case local_visible_message_id(socket, message_id) do
      {:ok, local_id} ->
        if current_user_missing?(socket) do
          {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
        else
          state = local_visible_post_state(socket, local_id)
          currently_liked = Map.get(state, :liked, false)
          currently_downvoted = Map.get(state, :downvoted, false)
          is_vote_post = local_visible_vote_post?(socket, local_id)

          if currently_liked do
            handle_event("unlike_post", %{"message_id" => local_id}, socket)
          else
            updated_socket =
              socket
              |> update_local_visible_interaction(local_id, fn current ->
                current
                |> Map.put(:liked, true)
                |> Map.put(:downvoted, false)
                |> Map.put(:like_delta, 0)
              end)
              |> adjust_local_visible_post_count(local_id, :like_count, 1)
              |> adjust_local_visible_post_count(
                local_id,
                :upvotes,
                if(is_vote_post, do: 1, else: 0)
              )
              |> adjust_local_visible_post_count(
                local_id,
                :dislike_count,
                if(currently_downvoted, do: -1, else: 0)
              )
              |> adjust_local_visible_post_count(
                local_id,
                :downvotes,
                if(currently_downvoted, do: -1, else: 0)
              )
              |> adjust_local_visible_post_count(
                local_id,
                :score,
                if(is_vote_post, do: if(currently_downvoted, do: 2, else: 1), else: 0)
              )

            case Elektrine.Social.like_post(socket.assigns.current_user.id, local_id) do
              {:ok, _} ->
                {:noreply, updated_socket}

              {:error, _} ->
                {:noreply,
                 updated_socket
                 |> update_local_visible_interaction(local_id, fn current ->
                   current
                   |> Map.put(:liked, false)
                   |> Map.put(:downvoted, currently_downvoted)
                 end)
                 |> adjust_local_visible_post_count(local_id, :like_count, -1)
                 |> adjust_local_visible_post_count(
                   local_id,
                   :upvotes,
                   if(is_vote_post, do: -1, else: 0)
                 )
                 |> adjust_local_visible_post_count(
                   local_id,
                   :dislike_count,
                   if(currently_downvoted, do: 1, else: 0)
                 )
                 |> adjust_local_visible_post_count(
                   local_id,
                   :downvotes,
                   if(currently_downvoted, do: 1, else: 0)
                 )
                 |> adjust_local_visible_post_count(
                   local_id,
                   :score,
                   if(is_vote_post, do: if(currently_downvoted, do: -2, else: -1), else: 0)
                 )
                 |> put_flash(:error, "Failed to like post")}
            end
          end
        end

      :error ->
        handle_event(
          "like_post",
          %{"post_id" => normalize_post_id_for_reply(socket, message_id)},
          socket
        )
    end
  end

  def handle_event("like_post", %{"id" => id}, socket) do
    handle_event("like_post", %{"post_id" => normalize_post_id_for_reply(socket, id)}, socket)
  end

  def handle_event("unlike_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          key = PostInteractions.interaction_key(post_id, message)

          case Elektrine.Social.unlike_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              # Update interaction state and decrement count
              current_state =
                socket.assigns.post_interactions[key] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, key, %{
                  liked: false,
                  boosted: Map.get(current_state, :boosted, false),
                  like_delta: Map.get(current_state, :like_delta, 0) - 1,
                  boost_delta: Map.get(current_state, :boost_delta, 0)
                })

              {:noreply, assign(socket, :post_interactions, post_interactions)}

            {:error, _} ->
              {:noreply, socket}
          end

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("unlike_post", %{"message_id" => message_id}, socket) do
    case local_visible_message_id(socket, message_id) do
      {:ok, local_id} ->
        if current_user_missing?(socket) do
          {:noreply, socket}
        else
          state = local_visible_post_state(socket, local_id)
          is_vote_post = local_visible_vote_post?(socket, local_id)

          updated_socket =
            socket
            |> update_local_visible_interaction(local_id, fn current ->
              current
              |> Map.put(:liked, false)
              |> Map.put(:like_delta, 0)
            end)
            |> adjust_local_visible_post_count(local_id, :like_count, -1)
            |> adjust_local_visible_post_count(
              local_id,
              :upvotes,
              if(is_vote_post, do: -1, else: 0)
            )
            |> adjust_local_visible_post_count(
              local_id,
              :score,
              if(is_vote_post, do: -1, else: 0)
            )

          case Elektrine.Social.unlike_post(socket.assigns.current_user.id, local_id) do
            {:ok, _} ->
              {:noreply, updated_socket}

            {:error, _} ->
              {:noreply,
               updated_socket
               |> update_local_visible_interaction(local_id, fn current ->
                 current
                 |> Map.put(:liked, true)
                 |> Map.put(:downvoted, Map.get(state, :downvoted, false))
               end)
               |> adjust_local_visible_post_count(local_id, :like_count, 1)
               |> adjust_local_visible_post_count(
                 local_id,
                 :upvotes,
                 if(is_vote_post, do: 1, else: 0)
               )
               |> adjust_local_visible_post_count(
                 local_id,
                 :score,
                 if(is_vote_post, do: 1, else: 0)
               )}
          end
        end

      :error ->
        handle_event(
          "unlike_post",
          %{"post_id" => normalize_post_id_for_reply(socket, message_id)},
          socket
        )
    end
  end

  def handle_event("unlike_post", %{"id" => id}, socket) do
    handle_event("unlike_post", %{"post_id" => normalize_post_id_for_reply(socket, id)}, socket)
  end

  def handle_event("upvote_post", %{"post_id" => post_id}, socket) do
    vote_remote_feed_post(socket, post_id, "up")
  end

  def handle_event("upvote_post", %{"message_id" => message_id}, socket) do
    handle_event("like_post", %{"message_id" => message_id}, socket)
  end

  def handle_event("upvote_post", %{"id" => id}, socket) do
    handle_event("upvote_post", %{"post_id" => normalize_post_id_for_reply(socket, id)}, socket)
  end

  def handle_event("unupvote_post", %{"post_id" => post_id}, socket) do
    vote_remote_feed_post(socket, post_id, "up")
  end

  def handle_event("unupvote_post", %{"message_id" => message_id}, socket) do
    handle_event("unlike_post", %{"message_id" => message_id}, socket)
  end

  def handle_event("unupvote_post", %{"id" => id}, socket) do
    handle_event("unupvote_post", %{"post_id" => normalize_post_id_for_reply(socket, id)}, socket)
  end

  def handle_event("downvote_post", %{"post_id" => post_id}, socket) do
    vote_remote_feed_post(socket, post_id, "down")
  end

  def handle_event("downvote_post", %{"message_id" => message_id}, socket) do
    case local_visible_message_id(socket, message_id) do
      {:ok, local_id} ->
        if current_user_missing?(socket) do
          {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
        else
          state = local_visible_post_state(socket, local_id)
          currently_liked = Map.get(state, :liked, false)
          currently_downvoted = Map.get(state, :downvoted, false)

          if currently_downvoted do
            handle_event("undownvote_post", %{"message_id" => local_id}, socket)
          else
            updated_socket =
              socket
              |> update_local_visible_interaction(local_id, fn current ->
                current
                |> Map.put(:liked, false)
                |> Map.put(:downvoted, true)
                |> Map.put(:like_delta, 0)
              end)
              |> adjust_local_visible_post_count(
                local_id,
                :score,
                if(currently_liked, do: -2, else: -1)
              )
              |> adjust_local_visible_post_count(
                local_id,
                :like_count,
                if(currently_liked, do: -1, else: 0)
              )
              |> adjust_local_visible_post_count(
                local_id,
                :upvotes,
                if(currently_liked, do: -1, else: 0)
              )
              |> adjust_local_visible_post_count(local_id, :dislike_count, 1)
              |> adjust_local_visible_post_count(local_id, :downvotes, 1)

            case Votes.vote_on_message(socket.assigns.current_user.id, local_id, "down") do
              {:ok, _} ->
                {:noreply, updated_socket}

              {:error, _} ->
                {:noreply,
                 updated_socket
                 |> update_local_visible_interaction(local_id, fn current ->
                   current
                   |> Map.put(:liked, currently_liked)
                   |> Map.put(:downvoted, false)
                 end)
                 |> adjust_local_visible_post_count(
                   local_id,
                   :score,
                   if(currently_liked, do: 2, else: 1)
                 )
                 |> adjust_local_visible_post_count(
                   local_id,
                   :like_count,
                   if(currently_liked, do: 1, else: 0)
                 )
                 |> adjust_local_visible_post_count(
                   local_id,
                   :upvotes,
                   if(currently_liked, do: 1, else: 0)
                 )
                 |> adjust_local_visible_post_count(local_id, :dislike_count, -1)
                 |> adjust_local_visible_post_count(local_id, :downvotes, -1)
                 |> put_flash(:error, "Failed to vote")}
            end
          end
        end

      :error ->
        handle_event(
          "downvote_post",
          %{"post_id" => normalize_post_id_for_reply(socket, message_id)},
          socket
        )
    end
  end

  def handle_event("downvote_post", %{"id" => id}, socket) do
    handle_event("downvote_post", %{"post_id" => normalize_post_id_for_reply(socket, id)}, socket)
  end

  def handle_event("undownvote_post", %{"post_id" => post_id}, socket) do
    vote_remote_feed_post(socket, post_id, "down")
  end

  def handle_event("undownvote_post", %{"message_id" => message_id}, socket) do
    case local_visible_message_id(socket, message_id) do
      {:ok, local_id} ->
        if current_user_missing?(socket) do
          {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
        else
          updated_socket =
            socket
            |> update_local_visible_interaction(local_id, fn current ->
              current
              |> Map.put(:downvoted, false)
              |> Map.put(:like_delta, 0)
            end)
            |> adjust_local_visible_post_count(local_id, :score, 1)
            |> adjust_local_visible_post_count(local_id, :dislike_count, -1)
            |> adjust_local_visible_post_count(local_id, :downvotes, -1)

          Social.vote_on_message(socket.assigns.current_user.id, local_id, "up")
          Social.unlike_post(socket.assigns.current_user.id, local_id)

          {:noreply, updated_socket}
        end

      :error ->
        handle_event(
          "undownvote_post",
          %{"post_id" => normalize_post_id_for_reply(socket, message_id)},
          socket
        )
    end
  end

  def handle_event("undownvote_post", %{"id" => id}, socket) do
    handle_event(
      "undownvote_post",
      %{"post_id" => normalize_post_id_for_reply(socket, id)},
      socket
    )
  end

  # Modal like toggle (for image modal)
  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    else
      # Check current like state
      current_state = socket.assigns.post_interactions[post_id] || %{liked: false}
      is_liked = Map.get(current_state, :liked, false)

      if is_liked do
        handle_event("unlike_post", %{"post_id" => post_id}, socket)
      else
        handle_event("like_post", %{"post_id" => post_id}, socket)
      end
    end
  end

  def handle_event("boost_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to boost posts")}
    else
      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          case Elektrine.Social.boost_post(socket.assigns.current_user.id, message.id) do
            {:ok, _boost} ->
              key = PostInteractions.interaction_key(post_id, message)

              # Update interaction state and decrement count
              current_state =
                socket.assigns.post_interactions[key] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, key, %{
                  liked: Map.get(current_state, :liked, false),
                  boosted: true,
                  like_delta: Map.get(current_state, :like_delta, 0),
                  boost_delta: Map.get(current_state, :boost_delta, 0) + 1
                })

              {:noreply,
               socket
               |> assign(:post_interactions, post_interactions)
               |> put_flash(:info, "Post boosted to your timeline!")}

            {:error, :already_boosted} ->
              {:noreply, put_flash(socket, :info, "You've already boosted this post")}

            {:error, :empty_post} ->
              {:noreply, put_flash(socket, :error, "Cannot boost empty posts")}

            {:error, :rate_limited} ->
              {:noreply,
               put_flash(socket, :error, "Slow down! You're boosting too fast (max 30/hour)")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to boost post")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process remote post")}
      end
    end
  end

  def handle_event("boost_post", %{"message_id" => message_id}, socket) do
    case local_visible_message_id(socket, message_id) do
      {:ok, local_id} ->
        if current_user_missing?(socket) do
          {:noreply, put_flash(socket, :error, "You must be signed in to boost posts")}
        else
          currently_boosted = Map.get(local_visible_post_state(socket, local_id), :boosted, false)

          if currently_boosted do
            handle_event("unboost_post", %{"message_id" => local_id}, socket)
          else
            updated_socket =
              socket
              |> update_local_visible_interaction(local_id, fn current ->
                current
                |> Map.put(:boosted, true)
                |> Map.put(:boost_delta, 0)
              end)
              |> adjust_local_visible_post_count(local_id, :share_count, 1)

            case Elektrine.Social.boost_post(socket.assigns.current_user.id, local_id) do
              {:ok, _} ->
                {:noreply, put_flash(updated_socket, :info, "Boosted!")}

              {:error, :already_boosted} ->
                {:noreply, put_flash(updated_socket, :info, "Already boosted")}

              {:error, :empty_post} ->
                {:noreply, put_flash(socket, :error, "Cannot boost empty posts")}

              {:error, :rate_limited} ->
                {:noreply, put_flash(socket, :error, "Slow down! You're boosting too fast")}

              {:error, _} ->
                {:noreply,
                 updated_socket
                 |> update_local_visible_interaction(local_id, fn current ->
                   current
                   |> Map.put(:boosted, false)
                   |> Map.put(:boost_delta, 0)
                 end)
                 |> adjust_local_visible_post_count(local_id, :share_count, -1)
                 |> put_flash(:error, "Failed to boost")}
            end
          end
        end

      :error ->
        handle_event(
          "boost_post",
          %{"post_id" => normalize_post_id_for_reply(socket, message_id)},
          socket
        )
    end
  end

  def handle_event("boost_post", %{"id" => id}, socket) do
    handle_event("boost_post", %{"post_id" => normalize_post_id_for_reply(socket, id)}, socket)
  end

  def handle_event("unboost_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          key = PostInteractions.interaction_key(post_id, message)

          case Elektrine.Social.unboost_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              # Update interaction state and decrement count
              current_state =
                socket.assigns.post_interactions[key] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, key, %{
                  liked: Map.get(current_state, :liked, false),
                  boosted: false,
                  like_delta: Map.get(current_state, :like_delta, 0),
                  boost_delta: Map.get(current_state, :boost_delta, 0) - 1
                })

              {:noreply, assign(socket, :post_interactions, post_interactions)}

            {:error, _} ->
              {:noreply, socket}
          end

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("unboost_post", %{"message_id" => message_id}, socket) do
    case local_visible_message_id(socket, message_id) do
      {:ok, local_id} ->
        if current_user_missing?(socket) do
          {:noreply, socket}
        else
          updated_socket =
            socket
            |> update_local_visible_interaction(local_id, fn current ->
              current
              |> Map.put(:boosted, false)
              |> Map.put(:boost_delta, 0)
            end)
            |> adjust_local_visible_post_count(local_id, :share_count, -1)

          case Elektrine.Social.unboost_post(socket.assigns.current_user.id, local_id) do
            {:ok, _} ->
              {:noreply, updated_socket}

            {:error, _} ->
              {:noreply,
               updated_socket
               |> update_local_visible_interaction(local_id, fn current ->
                 current
                 |> Map.put(:boosted, true)
                 |> Map.put(:boost_delta, 0)
               end)
               |> adjust_local_visible_post_count(local_id, :share_count, 1)
               |> put_flash(:error, "Failed to unboost")}
          end
        end

      :error ->
        handle_event(
          "unboost_post",
          %{"post_id" => normalize_post_id_for_reply(socket, message_id)},
          socket
        )
    end
  end

  def handle_event("unboost_post", %{"id" => id}, socket) do
    handle_event("unboost_post", %{"post_id" => normalize_post_id_for_reply(socket, id)}, socket)
  end

  def handle_event("quote_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to quote posts")}
    else
      case resolve_quote_target(post_id, socket) do
        {:ok, quote_target} ->
          quote_target_ap_id = quote_target.activitypub_id || post_id

          {:noreply,
           socket
           |> assign(:show_quote_modal, true)
           |> assign(:quote_target_post, quote_target)
           |> assign(:quote_target_message_id, quote_target.id)
           |> assign(:quote_target_activitypub_id, quote_target_ap_id)
           |> assign(:quote_content, "")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Post not found")}
      end
    end
  end

  def handle_event("quote_post", %{"message_id" => message_id}, socket) do
    handle_event(
      "quote_post",
      %{"post_id" => normalize_post_id_for_reply(socket, message_id)},
      socket
    )
  end

  def handle_event("quote_post", %{"id" => id}, socket) do
    handle_event("quote_post", %{"post_id" => normalize_post_id_for_reply(socket, id)}, socket)
  end

  def handle_event("vote_poll", params, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    else
      poll_id = params["poll_id"] || params["poll-id"]
      option_id = params["option_id"] || params["option-id"]

      with {poll_id, _} <- Integer.parse(to_string(poll_id)),
           {option_id, _} <- Integer.parse(to_string(option_id)) do
        case Social.vote_on_poll(poll_id, option_id, socket.assigns.current_user.id) do
          {:ok, _vote} ->
            poll = Repo.get!(Elektrine.Social.Poll, poll_id)

            message =
              poll.message_id |> Messaging.get_message() |> Repo.preload(poll: [options: []])

            if message do
              if message.federated && message.post_type == "poll" && message.poll do
                _ = Elektrine.ActivityPub.FetchRemotePollWorker.enqueue(message.id)
              end
            end

            Process.send_after(self(), :reload_local_posts_after_poll_refresh, 1_000)

            {:noreply,
             socket
             |> assign(:poll_refresh_nonce, System.unique_integer([:positive, :monotonic]))
             |> put_flash(:info, "Vote recorded")}

          {:error, :poll_closed} ->
            {:noreply, put_flash(socket, :error, "This poll has closed")}

          {:error, :invalid_option} ->
            {:noreply, put_flash(socket, :error, "Invalid poll option")}

          {:error, :self_vote} ->
            {:noreply, put_flash(socket, :error, "You cannot vote on your own poll")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to vote")}
        end
      else
        _ -> {:noreply, put_flash(socket, :error, "Invalid poll vote")}
      end
    end
  end

  def handle_event(
        "vote_remote_poll",
        %{"option_name" => option_name, "poll_id" => poll_id},
        socket
      ) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    else
      Elektrine.ActivityPub.Outbox.send_poll_vote(
        socket.assigns.current_user,
        poll_id,
        option_name,
        socket.assigns.remote_actor
      )

      Process.send_after(self(), :reload_local_posts_after_poll_refresh, 1_000)

      {:noreply,
       socket
       |> assign(:poll_refresh_nonce, System.unique_integer([:positive, :monotonic]))
       |> put_flash(:info, "Vote sent to #{socket.assigns.remote_actor.domain}")}
    end
  end

  def handle_event("close_quote_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_quote_modal, false)
     |> assign(:quote_target_post, nil)
     |> assign(:quote_target_message_id, nil)
     |> assign(:quote_target_activitypub_id, nil)
     |> assign(:quote_content, "")}
  end

  def handle_event("update_quote_content", params, socket) do
    content = params["content"] || params["value"] || ""
    {:noreply, assign(socket, :quote_content, content)}
  end

  def handle_event("submit_quote", params, socket) do
    content = params["content"] || params["value"] || socket.assigns.quote_content || ""

    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to quote posts")}
    else
      quote_target_message_id = socket.assigns.quote_target_message_id
      quote_target_ap_id = socket.assigns.quote_target_activitypub_id

      cond do
        is_nil(quote_target_message_id) ->
          {:noreply, put_flash(socket, :error, "Quote target not found")}

        not Elektrine.Strings.present?(content) ->
          {:noreply, put_flash(socket, :error, "Please add some content to your quote")}

        true ->
          case Social.create_quote_post(
                 socket.assigns.current_user.id,
                 quote_target_message_id,
                 content
               ) do
            {:ok, _quote_post} ->
              updated_local_posts =
                increment_quote_count_for_local_posts(
                  socket.assigns.local_posts,
                  quote_target_message_id,
                  quote_target_ap_id
                )

              updated_timeline_posts =
                increment_quote_count_for_remote_posts(
                  socket.assigns.timeline_posts,
                  quote_target_ap_id
                )

              {:noreply,
               socket
               |> assign(:local_posts, updated_local_posts)
               |> assign(:timeline_posts, updated_timeline_posts)
               |> assign(:show_quote_modal, false)
               |> assign(:quote_target_post, nil)
               |> assign(:quote_target_message_id, nil)
               |> assign(:quote_target_activitypub_id, nil)
               |> assign(:quote_content, "")
               |> put_flash(:info, "Quote posted!")}

            {:error, :empty_quote} ->
              {:noreply, put_flash(socket, :error, "Quote content cannot be empty")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to create quote")}
          end
      end
    end
  end

  def handle_event("react_to_post", %{"post_id" => post_id, "emoji" => emoji}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to react")}
    else
      user_id = socket.assigns.current_user.id

      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: socket.assigns[:remote_actor] && socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          alias Elektrine.Messaging.Reactions
          key = PostInteractions.interaction_key(post_id, message)

          existing_reaction =
            Repo.get_by(Elektrine.Social.MessageReaction,
              message_id: message.id,
              user_id: user_id,
              emoji: emoji
            )

          if existing_reaction do
            case Reactions.remove_reaction(message.id, user_id, emoji) do
              {:ok, _} ->
                updated_reactions =
                  PostInteractions.update_post_reactions(
                    socket.assigns.post_reactions,
                    key,
                    %{emoji: emoji, user_id: user_id},
                    :remove
                  )

                {:noreply, assign(socket, :post_reactions, updated_reactions)}

              {:error, _} ->
                {:noreply, socket}
            end
          else
            case Reactions.add_reaction(message.id, user_id, emoji) do
              {:ok, reaction} ->
                reaction = Repo.preload(reaction, [:user, :remote_actor])

                updated_reactions =
                  PostInteractions.update_post_reactions(
                    socket.assigns.post_reactions,
                    key,
                    reaction,
                    :add
                  )

                {:noreply, assign(socket, :post_reactions, updated_reactions)}

              {:error, :rate_limited} ->
                {:noreply, put_flash(socket, :error, "Slow down! You're reacting too fast")}

              {:error, _} ->
                {:noreply, socket}
            end
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process post")}
      end
    end
  end

  def handle_event("react_to_post", %{"message_id" => message_id, "emoji" => emoji}, socket) do
    handle_event(
      "react_to_post",
      %{"post_id" => normalize_post_id_for_reply(socket, message_id), "emoji" => emoji},
      socket
    )
  end

  # Save/bookmark post handlers
  def handle_event("save_post", %{"post_id" => post_id}, socket) do
    handle_event("save_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("save_post", %{"message_id" => message_id}, socket) do
    case local_visible_message_id(socket, message_id) do
      {:ok, local_id} ->
        if current_user_missing?(socket) do
          {:noreply, put_flash(socket, :error, "You must be signed in to save posts")}
        else
          updated_socket = update_local_visible_save(socket, local_id, true)

          case Social.save_post(socket.assigns.current_user.id, local_id) do
            {:ok, _} -> {:noreply, put_flash(updated_socket, :info, "Saved")}
            {:error, _} -> {:noreply, put_flash(updated_socket, :info, "Already saved")}
          end
        end

      :error ->
        if current_user_missing?(socket) do
          {:noreply, put_flash(socket, :error, "You must be signed in to save posts")}
        else
          case PostInteractions.resolve_message_for_interaction(message_id,
                 actor_uri: socket.assigns.remote_actor.uri
               ) do
            {:ok, message} ->
              case Social.save_post(socket.assigns.current_user.id, message.id) do
                {:ok, _} ->
                  user_saves = Map.get(socket.assigns, :user_saves, %{})
                  key = PostInteractions.interaction_key(message_id, message)

                  {:noreply,
                   socket
                   |> assign(:user_saves, Map.put(user_saves, key, true))
                   |> put_flash(:info, "Saved")}

                {:error, _} ->
                  user_saves = Map.get(socket.assigns, :user_saves, %{})
                  key = PostInteractions.interaction_key(message_id, message)

                  {:noreply,
                   socket
                   |> assign(:user_saves, Map.put(user_saves, key, true))
                   |> put_flash(:info, "Already saved")}
              end

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to save post")}
          end
        end
    end
  end

  def handle_event("unsave_post", %{"post_id" => post_id}, socket) do
    handle_event("unsave_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("unsave_post", %{"message_id" => message_id}, socket) do
    case local_visible_message_id(socket, message_id) do
      {:ok, local_id} ->
        if current_user_missing?(socket) do
          {:noreply, socket}
        else
          updated_socket = update_local_visible_save(socket, local_id, false)

          case Social.unsave_post(socket.assigns.current_user.id, local_id) do
            {:ok, _} ->
              {:noreply, put_flash(updated_socket, :info, "Removed from saved")}

            {:error, _} ->
              {:noreply,
               updated_socket
               |> update_local_visible_save(local_id, true)
               |> put_flash(:error, "Failed to unsave")}
          end
        end

      :error ->
        if current_user_missing?(socket) do
          {:noreply, socket}
        else
          case PostInteractions.resolve_message_for_interaction(message_id,
                 actor_uri: socket.assigns.remote_actor.uri
               ) do
            {:ok, message} ->
              case Social.unsave_post(socket.assigns.current_user.id, message.id) do
                {:ok, _} ->
                  user_saves = Map.get(socket.assigns, :user_saves, %{})
                  key = PostInteractions.interaction_key(message_id, message)

                  {:noreply,
                   socket
                   |> assign(:user_saves, Map.put(user_saves, key, false))
                   |> put_flash(:info, "Removed from saved")}

                {:error, _} ->
                  {:noreply, put_flash(socket, :error, "Failed to unsave")}
              end

            {:error, _} ->
              {:noreply, socket}
          end
        end
    end
  end

  defp resolve_quote_target(post_id, socket) do
    post_id = to_string(post_id)

    with {:ok, message} <- resolve_quote_target_message(post_id, socket),
         quote_target <- load_quote_target_post(message) do
      {:ok, quote_target}
    end
  end

  defp resolve_quote_target_message(post_id, socket) do
    case Enum.find(socket.assigns.local_posts, fn post ->
           (post.activitypub_id || to_string(post.id)) == post_id
         end) do
      %Elektrine.Social.Message{} = message ->
        {:ok, message}

      _ ->
        PostInteractions.resolve_message_for_interaction(post_id,
          actor_uri: socket.assigns.remote_actor.uri
        )
    end
  end

  defp load_quote_target_post(%Elektrine.Social.Message{id: id}) do
    MessagingMessages.get_timeline_post!(id, force: true)
  rescue
    _ -> MessagingMessages.get_timeline_post!(id)
  end

  defp increment_quote_count_for_local_posts(posts, target_message_id, target_activitypub_id) do
    Enum.map(posts, fn post ->
      if post.id == target_message_id || post.activitypub_id == target_activitypub_id do
        %{post | quote_count: (post.quote_count || 0) + 1}
      else
        post
      end
    end)
  end

  defp increment_quote_count_for_remote_posts(posts, target_activitypub_id) do
    Enum.map(posts, fn post ->
      if post["id"] == target_activitypub_id do
        quote_count =
          max(
            max(
              APHelpers.get_collection_total(post["quoteCount"]),
              APHelpers.get_collection_total(post["quote_count"])
            ),
            APHelpers.get_collection_total(get_in(post, ["pleroma", "quote_count"]))
          )

        Map.put(post, "quoteCount", quote_count + 1)
      else
        post
      end
    end)
  end

  defp vote_remote_feed_post(socket, post_id, vote_type) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    else
      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          interaction_key = PostInteractions.interaction_key(post_id, message)
          current_state = Map.get(socket.assigns.post_interactions, interaction_key, %{})
          current_vote = Map.get(current_state, :vote)
          current_vote_delta = Map.get(current_state, :vote_delta, 0)
          new_vote = if current_vote == vote_type, do: nil, else: vote_type
          vote_delta_change = vote_delta_change(current_vote, new_vote)

          case Votes.vote_on_message(socket.assigns.current_user.id, message.id, vote_type) do
            {:ok, _} ->
              updated_state = %{
                liked: Map.get(current_state, :liked, false),
                boosted: Map.get(current_state, :boosted, false),
                like_delta: Map.get(current_state, :like_delta, 0),
                boost_delta: Map.get(current_state, :boost_delta, 0),
                vote: new_vote,
                vote_delta: current_vote_delta + vote_delta_change
              }

              post_interactions =
                put_remote_post_interaction_state(
                  socket.assigns.post_interactions,
                  interaction_key,
                  message,
                  updated_state
                )

              {:noreply, assign(socket, :post_interactions, post_interactions)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to vote")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process remote post")}
      end
    end
  end

  defp vote_delta_change(nil, nil), do: 0
  defp vote_delta_change(nil, "up"), do: 1
  defp vote_delta_change(nil, "down"), do: -1
  defp vote_delta_change("up", nil), do: -1
  defp vote_delta_change("down", nil), do: 1
  defp vote_delta_change("up", "down"), do: -2
  defp vote_delta_change("down", "up"), do: 2
  defp vote_delta_change(_, _), do: 0
end
