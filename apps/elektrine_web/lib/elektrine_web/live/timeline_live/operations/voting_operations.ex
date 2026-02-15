defmodule ElektrineWeb.TimelineLive.Operations.VotingOperations do
  @moduledoc """
  Handles voting operations (likes, dislikes, boosts) for timeline posts.
  Extracted from TimelineLive.Index to improve code organization.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  alias Elektrine.Messaging.Messages, as: MessagingMessages
  alias Elektrine.Social
  alias Elektrine.Utils.SafeConvert
  alias ElektrineWeb.TimelineLive.Operations.Helpers

  import ElektrineWeb.Live.Helpers.PostStateHelpers

  # Like post handlers

  def handle_event("like_post", %{"post_id" => post_id}, socket) do
    handle_event("like_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("like_post", %{"message_id" => message_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    else
      user_id = socket.assigns.current_user.id
      message_id = SafeConvert.to_integer!(message_id, message_id)

      if message_id == :temp do
        {:noreply, socket}
      else
        currently_liked = Map.get(socket.assigns.user_likes, message_id, false)

        if currently_liked do
          updated_socket =
            socket
            |> update_user_like_status(message_id, false)
            |> update_post_count(message_id, :like_count, -1)
            |> update_post_interaction(message_id, :liked, false, -1)

          case Social.unlike_post(user_id, message_id) do
            {:ok, _} ->
              {:noreply, updated_socket}

            {:error, _} ->
              {:noreply,
               socket
               |> update_user_like_status(message_id, true)
               |> update_post_count(message_id, :like_count, 1)
               |> update_post_interaction(message_id, :liked, true, 1)
               |> put_flash(:error, "Failed to unlike post")}
          end
        else
          # Check if currently downvoted - if so, we need to clear it and adjust score by +2
          currently_downvoted = Map.get(socket.assigns.user_downvotes, message_id, false)
          score_adjustment = if currently_downvoted, do: 2, else: 1

          updated_socket =
            socket
            |> update_user_like_status(message_id, true)
            |> update_user_downvote_status(message_id, false)
            |> update_post_count(message_id, :like_count, 1)
            |> update_post_count(
              message_id,
              :dislike_count,
              if(currently_downvoted, do: -1, else: 0)
            )
            |> update_post_interaction(message_id, :liked, true, score_adjustment)
            # Clear downvote state if was downvoted
            |> (fn s ->
                  if currently_downvoted,
                    do: update_post_interaction(s, message_id, :downvoted, false, 0),
                    else: s
                end).()

          case Social.like_post(user_id, message_id) do
            {:ok, _} ->
              Task.start(fn ->
                Elektrine.Accounts.TrustLevel.increment_stat(user_id, :likes_given)

                post = Enum.find(socket.assigns.timeline_posts, &(&1.id == message_id))

                message =
                  if post do
                    post
                  else
                    socket.assigns.post_replies
                    |> Map.values()
                    |> List.flatten()
                    |> Enum.find(&(&1.id == message_id))
                  end

                if message && !message.federated && message.sender_id &&
                     message.sender_id != user_id do
                  Elektrine.Accounts.TrustLevel.increment_stat(message.sender_id, :likes_received)
                end
              end)

              {:noreply, updated_socket}

            {:error, _} ->
              # Rollback - restore original state
              {:noreply,
               socket
               |> update_user_like_status(message_id, false)
               |> update_user_downvote_status(message_id, currently_downvoted)
               |> update_post_count(message_id, :like_count, -1)
               |> update_post_count(
                 message_id,
                 :dislike_count,
                 if(currently_downvoted, do: 1, else: 0)
               )
               |> update_post_interaction(message_id, :liked, false, -score_adjustment)
               |> (fn s ->
                     if currently_downvoted,
                       do: update_post_interaction(s, message_id, :downvoted, true, 0),
                       else: s
                   end).()
               |> put_flash(:error, "Failed to like post")}
          end
        end
      end
    end
  end

  def handle_event("unlike_post", params, socket) do
    handle_event("like_post", params, socket)
  end

  # Modal like toggle (for image modal)
  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    handle_event("like_post", %{"message_id" => post_id}, socket)
  end

  # Downvote post handlers

  def handle_event("downvote_post", %{"post_id" => post_id}, socket) do
    handle_event("downvote_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("downvote_post", %{"message_id" => message_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    else
      message_id = SafeConvert.to_integer!(message_id, message_id)

      if message_id == :temp do
        {:noreply, socket}
      else
        currently_liked = Map.get(socket.assigns.user_likes, message_id, false)
        currently_downvoted = Map.get(socket.assigns.user_downvotes, message_id, false)

        if currently_downvoted do
          # Already downvoted - remove the downvote (toggle off)
          updated_socket =
            socket
            |> update_user_downvote_status(message_id, false)
            |> update_post_count(message_id, :score, 1)
            |> update_post_count(message_id, :dislike_count, -1)
            |> update_post_interaction(message_id, :downvoted, false, 1)

          Task.start(fn ->
            Social.vote_on_message(socket.assigns.current_user.id, message_id, "up")
            Social.unlike_post(socket.assigns.current_user.id, message_id)
          end)

          {:noreply, updated_socket}
        else
          # Not downvoted - apply downvote
          # Score adjustment: -1 for downvote, -2 if also removing an upvote
          score_adjustment = if currently_liked, do: -2, else: -1

          updated_socket =
            socket
            |> update_user_like_status(message_id, false)
            |> update_user_downvote_status(message_id, true)
            |> update_post_count(message_id, :score, score_adjustment)
            |> update_post_count(message_id, :like_count, if(currently_liked, do: -1, else: 0))
            |> update_post_count(message_id, :dislike_count, 1)
            |> update_post_interaction(message_id, :downvoted, true, score_adjustment)
            |> (fn s ->
                  if currently_liked,
                    do: update_post_interaction(s, message_id, :liked, false, 0),
                    else: s
                end).()

          Task.start(fn ->
            Social.vote_on_message(socket.assigns.current_user.id, message_id, "down")
          end)

          {:noreply, updated_socket}
        end
      end
    end
  end

  # Undownvote post handlers

  def handle_event("undownvote_post", %{"post_id" => post_id}, socket) do
    handle_event("undownvote_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("undownvote_post", %{"message_id" => message_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, socket}
    else
      message_id = SafeConvert.to_integer!(message_id, message_id)

      if message_id == :temp do
        {:noreply, socket}
      else
        # Un-downvoting adds 1 to score (removes the downvote penalty)
        updated_socket =
          socket
          |> update_user_downvote_status(message_id, false)
          |> update_post_count(message_id, :score, 1)
          |> update_post_count(message_id, :dislike_count, -1)
          |> update_post_interaction(message_id, :downvoted, false, 1)

        Task.start(fn ->
          Social.vote_on_message(socket.assigns.current_user.id, message_id, "up")
          Social.unlike_post(socket.assigns.current_user.id, message_id)
        end)

        {:noreply, updated_socket}
      end
    end
  end

  # Boost post handlers

  def handle_event("boost_post", %{"post_id" => post_id}, socket) do
    handle_event("boost_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("boost_post", %{"message_id" => message_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to boost posts")}
    else
      user_id = socket.assigns.current_user.id
      message_id = SafeConvert.to_integer!(message_id, message_id)

      if message_id == :temp do
        {:noreply, socket}
      else
        currently_boosted = Map.get(socket.assigns.user_boosts, message_id, false)

        if currently_boosted do
          case Social.unboost_post(user_id, message_id) do
            {:ok, _} ->
              updated_posts =
                Enum.reject(socket.assigns.timeline_posts, fn post ->
                  post.sender_id == user_id && post.shared_message_id == message_id
                end)

              updated_posts_with_count =
                Enum.map(updated_posts, fn post ->
                  cond do
                    post.id == message_id ->
                      Map.put(post, :share_count, max(0, (post.share_count || 0) - 1))

                    post.shared_message_id == message_id && post.shared_message ->
                      updated_shared =
                        Map.put(
                          post.shared_message,
                          :share_count,
                          max(0, (post.shared_message.share_count || 0) - 1)
                        )

                      Map.put(post, :shared_message, updated_shared)

                    true ->
                      post
                  end
                end)

              {:noreply,
               socket
               |> Phoenix.Component.update(:user_boosts, &Map.put(&1, message_id, false))
               |> assign(:timeline_posts, updated_posts_with_count)
               |> Helpers.apply_timeline_filter()
               |> put_flash(:info, "Unboosted")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to unboost")}
          end
        else
          case Social.boost_post(user_id, message_id) do
            {:ok, _} ->
              import Ecto.Query

              boost_post =
                from(m in Elektrine.Messaging.Message,
                  where: m.sender_id == ^user_id and m.shared_message_id == ^message_id,
                  order_by: [desc: m.id],
                  limit: 1,
                  preload: [
                    sender: [:profile],
                    conversation: [],
                    link_preview: [],
                    hashtags: [],
                    reply_to: [sender: [:profile]],
                    shared_message: [sender: [:profile], conversation: [], remote_actor: []]
                  ]
                )
                |> Elektrine.Repo.one()

              updated_posts =
                if boost_post do
                  [boost_post | socket.assigns.timeline_posts]
                else
                  socket.assigns.timeline_posts
                end

              updated_posts_with_count =
                Enum.map(updated_posts, fn post ->
                  cond do
                    post.id == message_id ->
                      Map.put(post, :share_count, (post.share_count || 0) + 1)

                    post.shared_message_id == message_id && post.shared_message ->
                      updated_shared =
                        Map.put(
                          post.shared_message,
                          :share_count,
                          (post.shared_message.share_count || 0) + 1
                        )

                      Map.put(post, :shared_message, updated_shared)

                    true ->
                      post
                  end
                end)

              {:noreply,
               socket
               |> Phoenix.Component.update(:user_boosts, &Map.put(&1, message_id, true))
               |> assign(:timeline_posts, updated_posts_with_count)
               |> Helpers.apply_timeline_filter()
               |> put_flash(:info, "Boosted!")}

            {:error, :already_boosted} ->
              {:noreply, put_flash(socket, :info, "Already boosted")}

            {:error, :empty_post} ->
              {:noreply, put_flash(socket, :error, "Cannot boost empty posts")}

            {:error, :rate_limited} ->
              {:noreply, put_flash(socket, :error, "Slow down! You're boosting too fast")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to boost")}
          end
        end
      end
    end
  end

  def handle_event("unboost_post", params, socket) do
    handle_event("boost_post", params, socket)
  end

  # Save post handlers

  def handle_event("save_post", %{"post_id" => post_id}, socket) do
    handle_event("save_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("save_post", %{"message_id" => message_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to save posts")}
    else
      user_id = socket.assigns.current_user.id
      message_id = SafeConvert.to_integer!(message_id, message_id)

      if message_id == :temp do
        {:noreply, socket}
      else
        case Social.save_post(user_id, message_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> update_user_save_status(message_id, true)
             |> put_flash(:info, "Saved")}

          {:error, _changeset} ->
            # Might already be saved
            {:noreply,
             socket
             |> update_user_save_status(message_id, true)
             |> put_flash(:info, "Already saved")}
        end
      end
    end
  end

  def handle_event("unsave_post", %{"post_id" => post_id}, socket) do
    handle_event("unsave_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("unsave_post", %{"message_id" => message_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id
      message_id = SafeConvert.to_integer!(message_id, message_id)

      if message_id == :temp do
        {:noreply, socket}
      else
        case Social.unsave_post(user_id, message_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> update_user_save_status(message_id, false)
             |> put_flash(:info, "Removed from saved")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to unsave")}
        end
      end
    end
  end

  # Save RSS item handlers

  def handle_event("save_rss_item", %{"item_id" => item_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id
      item_id = SafeConvert.to_integer!(item_id, item_id)

      case Social.save_rss_item(user_id, item_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> update_rss_item_save_status(item_id, true)
           |> put_flash(:info, "Saved")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save")}
      end
    end
  end

  def handle_event("unsave_rss_item", %{"item_id" => item_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id
      item_id = SafeConvert.to_integer!(item_id, item_id)

      case Social.unsave_rss_item(user_id, item_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> update_rss_item_save_status(item_id, false)
           |> put_flash(:info, "Removed from saved")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to unsave")}
      end
    end
  end

  # Quote post handlers

  def handle_event("quote_post", %{"post_id" => post_id}, socket) do
    handle_event("quote_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("quote_post", %{"message_id" => message_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to quote posts")}
    else
      message_id = SafeConvert.to_integer!(message_id, message_id)

      if message_id == :temp do
        {:noreply, socket}
      else
        # Find the post to quote
        post = Enum.find(socket.assigns.timeline_posts, &(&1.id == message_id))

        # Also check in replies
        post =
          post ||
            socket.assigns.post_replies
            |> Map.values()
            |> List.flatten()
            |> Enum.find(&(&1.id == message_id))

        if post do
          {:noreply,
           socket
           |> assign(:quote_target_post, post)
           |> assign(:show_quote_modal, true)
           |> assign(:quote_content, "")}
        else
          {:noreply, put_flash(socket, :error, "Post not found")}
        end
      end
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

    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to quote posts")}
    else
      user = socket.assigns.current_user
      quote_target = socket.assigns.quote_target_post

      if quote_target && String.trim(content) != "" do
        case Social.create_quote_post(user.id, quote_target.id, content) do
          {:ok, quote_post} ->
            # Reload with associations
            import Ecto.Query
            preloads = MessagingMessages.timeline_post_preloads()

            reloaded =
              from(m in Elektrine.Messaging.Message,
                where: m.id == ^quote_post.id,
                preload: ^preloads
              )
              |> Elektrine.Repo.one()
              |> Elektrine.Messaging.Message.decrypt_content()

            # Update quote count on the quoted post
            updated_posts =
              Enum.map(socket.assigns.timeline_posts, fn post ->
                if post.id == quote_target.id do
                  Map.put(post, :quote_count, (post.quote_count || 0) + 1)
                else
                  post
                end
              end)

            {:noreply,
             socket
             |> assign(:timeline_posts, [reloaded | updated_posts])
             |> Helpers.apply_timeline_filter()
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
    end
  end

  # Poll voting handler

  def handle_event("vote_poll", params, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    else
      poll_id = params["poll_id"] || params["poll-id"]
      option_id = params["option_id"] || params["option-id"]

      poll_id = SafeConvert.to_integer!(poll_id, poll_id)
      option_id = SafeConvert.to_integer!(option_id, option_id)

      case Social.vote_on_poll(poll_id, option_id, socket.assigns.current_user.id) do
        {:ok, _vote} ->
          # Find the message that contains this poll and reload it
          poll = Elektrine.Repo.get!(Elektrine.Social.Poll, poll_id)
          message_id = poll.message_id

          # Reload the message with fresh poll data
          updated_message =
            Elektrine.Repo.get!(Elektrine.Messaging.Message, message_id)
            |> Elektrine.Repo.preload(MessagingMessages.timeline_post_preloads(), force: true)
            |> Elektrine.Messaging.Message.decrypt_content()

          # Update the post in timeline_posts
          updated_timeline_posts =
            Enum.map(socket.assigns.timeline_posts, fn post ->
              if post.id == message_id, do: updated_message, else: post
            end)

          {:noreply, assign(socket, :timeline_posts, updated_timeline_posts)}

        {:error, :poll_closed} ->
          {:noreply, put_flash(socket, :error, "This poll has closed")}

        {:error, :invalid_option} ->
          {:noreply, put_flash(socket, :error, "Invalid poll option")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to vote")}
      end
    end
  end

  # Emoji Reaction handler

  def handle_event("react_to_post", %{"post_id" => post_id, "emoji" => emoji}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to react")}
    else
      user_id = socket.assigns.current_user.id
      message_id = SafeConvert.to_integer!(post_id, post_id)

      if message_id == :temp do
        {:noreply, socket}
      else
        alias Elektrine.Messaging.Reactions

        # Check if user already has this reaction in the database
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
      end
    end
  end

  defp update_post_reactions(socket, message_id, reaction, action) do
    current_reactions = Map.get(socket.assigns, :post_reactions, %{})
    post_reactions = Map.get(current_reactions, message_id, [])

    updated =
      case action do
        :add ->
          # Add the reaction to the list (if not already present)
          if Enum.any?(post_reactions, fn r ->
               r.emoji == reaction.emoji && r.user_id == reaction.user_id
             end) do
            post_reactions
          else
            [reaction | post_reactions]
          end

        :remove ->
          # Remove the reaction from the list
          Enum.reject(post_reactions, fn r ->
            r.emoji == reaction.emoji && r.user_id == reaction.user_id
          end)
      end

    Map.put(current_reactions, message_id, updated)
  end

  # Private helper functions

  defp update_user_like_status(socket, message_id, liked) do
    assign(socket, :user_likes, Map.put(socket.assigns.user_likes, message_id, liked))
  end

  defp update_user_downvote_status(socket, message_id, downvoted) do
    assign(socket, :user_downvotes, Map.put(socket.assigns.user_downvotes, message_id, downvoted))
  end

  defp update_post_interaction(socket, message_id, :liked, liked, delta) do
    post = Enum.find(socket.assigns.timeline_posts || [], fn p -> p.id == message_id end)
    key = if post && post.activitypub_id, do: post.activitypub_id, else: to_string(message_id)

    current =
      Map.get(socket.assigns.post_interactions, key, %{
        liked: false,
        like_delta: 0,
        downvoted: false
      })

    new_delta = current.like_delta + delta
    updated = Map.merge(current, %{liked: liked, like_delta: new_delta})
    assign(socket, :post_interactions, Map.put(socket.assigns.post_interactions, key, updated))
  end

  defp update_post_interaction(socket, message_id, :downvoted, downvoted, delta) do
    post = Enum.find(socket.assigns.timeline_posts || [], fn p -> p.id == message_id end)
    key = if post && post.activitypub_id, do: post.activitypub_id, else: to_string(message_id)

    current =
      Map.get(socket.assigns.post_interactions, key, %{
        liked: false,
        like_delta: 0,
        downvoted: false
      })

    new_delta = current.like_delta + delta
    updated = Map.merge(current, %{downvoted: downvoted, like_delta: new_delta})
    assign(socket, :post_interactions, Map.put(socket.assigns.post_interactions, key, updated))
  end

  defp update_user_save_status(socket, message_id, saved) do
    assign(socket, :user_saves, Map.put(socket.assigns.user_saves, message_id, saved))
  end

  defp update_rss_item_save_status(socket, item_id, saved) do
    rss_saves = Map.get(socket.assigns, :rss_saves, %{})
    assign(socket, :rss_saves, Map.put(rss_saves, item_id, saved))
  end
end
