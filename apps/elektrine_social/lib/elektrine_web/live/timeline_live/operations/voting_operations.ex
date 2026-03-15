defmodule ElektrineWeb.TimelineLive.Operations.VotingOperations do
  @moduledoc "Handles voting operations (likes, dislikes, boosts) for timeline posts.\nExtracted from TimelineLive.Index to improve code organization.\n"
  import Phoenix.LiveView
  import Phoenix.Component
  alias Elektrine.Messaging.Messages, as: MessagingMessages
  alias Elektrine.Social
  alias Elektrine.Utils.SafeConvert
  alias ElektrineWeb.Live.PostInteractions
  alias ElektrineWeb.TimelineLive.Operations.Helpers
  import ElektrineWeb.Live.Helpers.PostStateHelpers

  def handle_event("like_post", %{"post_id" => post_id}, socket) do
    handle_event("like_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("like_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
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
            |> update_lemmy_score(message_id, -1)

          case Social.unlike_post(user_id, message_id) do
            {:ok, _} ->
              {:noreply, Helpers.touch_interaction_posts(updated_socket, message_id)}

            {:error, _} ->
              {:noreply,
               socket
               |> update_user_like_status(message_id, true)
               |> update_post_count(message_id, :like_count, 1)
               |> update_post_interaction(message_id, :liked, true, 1)
               |> update_lemmy_score(message_id, 1)
               |> Helpers.touch_interaction_posts(message_id)
               |> put_flash(:error, "Failed to unlike post")}
          end
        else
          currently_downvoted = Map.get(socket.assigns.user_downvotes, message_id, false)
          like_delta_adjustment = 1
          lemmy_score_delta = if(currently_downvoted, do: 2, else: 1)

          updated_socket =
            socket
            |> update_user_like_status(message_id, true)
            |> update_user_downvote_status(message_id, false)
            |> update_post_count(message_id, :like_count, 1)
            |> update_post_count(
              message_id,
              :dislike_count,
              if currently_downvoted do
                -1
              else
                0
              end
            )
            |> update_post_interaction(message_id, :liked, true, like_delta_adjustment)
            |> update_lemmy_score(message_id, lemmy_score_delta)

          updated_socket =
            if currently_downvoted do
              update_post_interaction(updated_socket, message_id, :downvoted, false, 0)
            else
              updated_socket
            end

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

              {:noreply, Helpers.touch_interaction_posts(updated_socket, message_id)}

            {:error, _} ->
              error_socket =
                socket
                |> update_user_like_status(message_id, false)
                |> update_user_downvote_status(message_id, currently_downvoted)
                |> update_post_count(message_id, :like_count, -1)
                |> update_post_count(
                  message_id,
                  :dislike_count,
                  if currently_downvoted do
                    1
                  else
                    0
                  end
                )
                |> update_post_interaction(message_id, :liked, false, -like_delta_adjustment)
                |> update_lemmy_score(message_id, -lemmy_score_delta)

              error_socket =
                if currently_downvoted do
                  update_post_interaction(error_socket, message_id, :downvoted, true, 0)
                else
                  error_socket
                end

              {:noreply,
               error_socket
               |> Helpers.touch_interaction_posts(message_id)
               |> put_flash(:error, "Failed to like post")}
          end
        end
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    end
  end

  def handle_event("unlike_post", params, socket) do
    handle_event("like_post", params, socket)
  end

  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    handle_event("like_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("downvote_post", %{"post_id" => post_id}, socket) do
    handle_event("downvote_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("downvote_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      message_id = SafeConvert.to_integer!(message_id, message_id)

      if message_id == :temp do
        {:noreply, socket}
      else
        currently_liked = Map.get(socket.assigns.user_likes, message_id, false)
        currently_downvoted = Map.get(socket.assigns.user_downvotes, message_id, false)

        if currently_downvoted do
          updated_socket =
            socket
            |> update_user_downvote_status(message_id, false)
            |> update_post_count(message_id, :score, 1)
            |> update_post_count(message_id, :dislike_count, -1)
            |> update_post_interaction(message_id, :downvoted, false, 0)
            |> update_lemmy_score(message_id, 1)

          Task.start(fn ->
            Social.vote_on_message(socket.assigns.current_user.id, message_id, "up")
            Social.unlike_post(socket.assigns.current_user.id, message_id)
          end)

          {:noreply, Helpers.touch_interaction_posts(updated_socket, message_id)}
        else
          score_adjustment =
            if currently_liked do
              -2
            else
              -1
            end

          like_delta_adjustment =
            if currently_liked do
              -1
            else
              0
            end

          updated_socket =
            socket
            |> update_user_like_status(message_id, false)
            |> update_user_downvote_status(message_id, true)
            |> update_post_count(message_id, :score, score_adjustment)
            |> update_post_count(
              message_id,
              :like_count,
              if currently_liked do
                -1
              else
                0
              end
            )
            |> update_post_count(message_id, :dislike_count, 1)
            |> update_post_interaction(message_id, :downvoted, true, like_delta_adjustment)
            |> update_lemmy_score(message_id, score_adjustment)

          updated_socket =
            if currently_liked do
              update_post_interaction(updated_socket, message_id, :liked, false, 0)
            else
              updated_socket
            end

          Task.start(fn ->
            Social.vote_on_message(socket.assigns.current_user.id, message_id, "down")
          end)

          {:noreply, Helpers.touch_interaction_posts(updated_socket, message_id)}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    end
  end

  def handle_event("undownvote_post", %{"post_id" => post_id}, socket) do
    handle_event("undownvote_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("undownvote_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      message_id = SafeConvert.to_integer!(message_id, message_id)

      if message_id == :temp do
        {:noreply, socket}
      else
        updated_socket =
          socket
          |> update_user_downvote_status(message_id, false)
          |> update_post_count(message_id, :score, 1)
          |> update_post_count(message_id, :dislike_count, -1)
          |> update_post_interaction(message_id, :downvoted, false, 0)
          |> update_lemmy_score(message_id, 1)

        Task.start(fn ->
          Social.vote_on_message(socket.assigns.current_user.id, message_id, "up")
          Social.unlike_post(socket.assigns.current_user.id, message_id)
        end)

        {:noreply, Helpers.touch_interaction_posts(updated_socket, message_id)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("boost_post", %{"post_id" => post_id}, socket) do
    handle_event("boost_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("boost_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id
      message_id = SafeConvert.to_integer!(message_id, message_id)

      if message_id == :temp do
        {:noreply, socket}
      else
        currently_boosted = Map.get(socket.assigns.user_boosts, message_id, false)

        if currently_boosted do
          case Social.unboost_post(user_id, message_id) do
            {:ok, _} ->
              update_fn = fn posts ->
                posts
                |> Enum.reject(fn post ->
                  post.sender_id == user_id && post.shared_message_id == message_id
                end)
                |> Enum.map(fn post ->
                  cond do
                    post.id == message_id ->
                      Map.put(post, :share_count, max(0, (post.share_count || 0) - 1))

                    post.shared_message_id == message_id &&
                      Ecto.assoc_loaded?(post.shared_message) && is_map(post.shared_message) ->
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
                |> Helpers.dedupe_posts()
              end

              updated_current_posts = update_fn.(socket.assigns.timeline_posts || [])
              updated_base_posts = update_fn.(socket.assigns.base_timeline_posts || [])

              {:noreply,
               socket
               |> Phoenix.Component.update(:user_boosts, &Map.put(&1, message_id, false))
               |> Helpers.assign_current_and_base_posts(updated_current_posts, updated_base_posts)
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

              update_fn = fn posts ->
                posts =
                  if boost_post do
                    [boost_post | posts]
                  else
                    posts
                  end

                posts
                |> Enum.map(fn post ->
                  cond do
                    post.id == message_id ->
                      Map.put(post, :share_count, (post.share_count || 0) + 1)

                    post.shared_message_id == message_id &&
                      Ecto.assoc_loaded?(post.shared_message) && is_map(post.shared_message) ->
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
                |> Helpers.dedupe_posts()
              end

              updated_current_posts = update_fn.(socket.assigns.timeline_posts || [])
              updated_base_posts = update_fn.(socket.assigns.base_timeline_posts || [])

              {:noreply,
               socket
               |> Phoenix.Component.update(:user_boosts, &Map.put(&1, message_id, true))
               |> Helpers.assign_current_and_base_posts(updated_current_posts, updated_base_posts)
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
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to boost posts")}
    end
  end

  def handle_event("unboost_post", params, socket) do
    handle_event("boost_post", params, socket)
  end

  def handle_event("save_post", %{"post_id" => post_id}, socket) do
    handle_event("save_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("save_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
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
             |> Helpers.touch_interaction_posts(message_id)
             |> put_flash(:info, "Saved")}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> update_user_save_status(message_id, true)
             |> Helpers.touch_interaction_posts(message_id)
             |> put_flash(:info, "Already saved")}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to save posts")}
    end
  end

  def handle_event("unsave_post", %{"post_id" => post_id}, socket) do
    handle_event("unsave_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("unsave_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
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
             |> Helpers.touch_interaction_posts(message_id)
             |> put_flash(:info, "Removed from saved")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to unsave")}
        end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_rss_item", %{"item_id" => item_id}, socket) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id
      item_id = SafeConvert.to_integer!(item_id, item_id)

      case Social.save_rss_item(user_id, item_id) do
        {:ok, _} ->
          {:noreply,
           socket |> update_rss_item_save_status(item_id, true) |> put_flash(:info, "Saved")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("unsave_rss_item", %{"item_id" => item_id}, socket) do
    if socket.assigns[:current_user] do
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
    else
      {:noreply, socket}
    end
  end

  def handle_event("quote_post", %{"post_id" => post_id}, socket) do
    handle_event("quote_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("quote_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      message_id = SafeConvert.to_integer!(message_id, message_id)

      if message_id == :temp do
        {:noreply, socket}
      else
        post = Enum.find(socket.assigns.timeline_posts, &(&1.id == message_id))

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
          {:ok, quote_post} ->
            import Ecto.Query
            preloads = MessagingMessages.timeline_post_preloads()

            reloaded =
              from(m in Elektrine.Messaging.Message,
                where: m.id == ^quote_post.id,
                preload: ^preloads
              )
              |> Elektrine.Repo.one()
              |> Elektrine.Messaging.Message.decrypt_content()

            update_fn = fn posts ->
              posts
              |> Enum.map(fn post ->
                if post.id == quote_target.id do
                  Map.put(post, :quote_count, (post.quote_count || 0) + 1)
                else
                  post
                end
              end)
              |> then(fn posts -> [reloaded | posts] end)
              |> Helpers.dedupe_posts()
            end

            updated_current_posts = update_fn.(socket.assigns.timeline_posts || [])
            updated_base_posts = update_fn.(socket.assigns.base_timeline_posts || [])

            {:noreply,
             socket
             |> Helpers.assign_current_and_base_posts(updated_current_posts, updated_base_posts)
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
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to quote posts")}
    end
  end

  def handle_event("vote_poll", params, socket) do
    if socket.assigns[:current_user] do
      poll_id = params["poll_id"] || params["poll-id"]
      option_id = params["option_id"] || params["option-id"]
      poll_id = SafeConvert.to_integer!(poll_id, poll_id)
      option_id = SafeConvert.to_integer!(option_id, option_id)

      case Social.vote_on_poll(poll_id, option_id, socket.assigns.current_user.id) do
        {:ok, _vote} ->
          poll = Elektrine.Repo.get!(Elektrine.Social.Poll, poll_id)
          message_id = poll.message_id

          updated_message =
            Elektrine.Repo.get!(Elektrine.Messaging.Message, message_id)
            |> Elektrine.Repo.preload(MessagingMessages.timeline_post_preloads(), force: true)
            |> Elektrine.Messaging.Message.decrypt_content()

          updated_timeline_posts =
            Enum.map(socket.assigns.timeline_posts, fn post ->
              if post.id == message_id do
                updated_message
              else
                post
              end
            end)

          {:noreply,
           assign(socket, :timeline_posts, Helpers.dedupe_posts(updated_timeline_posts))}

        {:error, :poll_closed} ->
          {:noreply, put_flash(socket, :error, "This poll has closed")}

        {:error, :invalid_option} ->
          {:noreply, put_flash(socket, :error, "Invalid poll option")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to vote")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    end
  end

  def handle_event(
        "react_to_post",
        %{"message_id" => message_id, "emoji" => emoji} = params,
        socket
      ) do
    actor_uri = normalize_reaction_actor_uri(Map.get(params, "actor_uri"))

    %{"post_id" => message_id, "emoji" => emoji}
    |> maybe_put_reaction_actor_uri(actor_uri)
    |> then(&handle_event("react_to_post", &1, socket))
  end

  def handle_event("react_to_post", %{"post_id" => post_id, "emoji" => emoji} = params, socket) do
    if socket.assigns[:current_user] do
      normalized_post_id = normalize_reaction_post_id(post_id)
      reaction_actor_uri = normalize_reaction_actor_uri(Map.get(params, "actor_uri"))

      if normalized_post_id in [:temp, "temp"] do
        {:noreply, socket}
      else
        case PostInteractions.resolve_message_for_interaction(
               normalized_post_id,
               actor_uri: reaction_actor_uri
             ) do
          {:ok, message} ->
            user_id = socket.assigns.current_user.id
            reaction_key = reaction_key_for_post_id(normalized_post_id)
            alias Elektrine.Messaging.Reactions

            existing_reaction =
              Elektrine.Repo.get_by(Elektrine.Messaging.MessageReaction,
                message_id: message.id,
                user_id: user_id,
                emoji: emoji
              )

            if existing_reaction do
              case Reactions.remove_reaction(message.id, user_id, emoji) do
                {:ok, _} ->
                  updated_reactions =
                    update_post_reactions(
                      socket,
                      reaction_key,
                      %{emoji: emoji, user_id: user_id},
                      :remove
                    )

                  {:noreply,
                   socket
                   |> assign(:post_reactions, updated_reactions)
                   |> Helpers.touch_interaction_posts(message.id)}

                {:error, _} ->
                  {:noreply, socket}
              end
            else
              case Reactions.add_reaction(message.id, user_id, emoji) do
                {:ok, reaction} ->
                  reaction = Elektrine.Repo.preload(reaction, [:user, :remote_actor])
                  updated_reactions = update_post_reactions(socket, reaction_key, reaction, :add)

                  {:noreply,
                   socket
                   |> assign(:post_reactions, updated_reactions)
                   |> Helpers.touch_interaction_posts(message.id)}

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
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to react")}
    end
  end

  defp normalize_reaction_post_id(post_id) when is_binary(post_id), do: String.trim(post_id)
  defp normalize_reaction_post_id(post_id), do: post_id

  defp normalize_reaction_actor_uri(actor_uri) when is_binary(actor_uri) do
    case String.trim(actor_uri) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_reaction_actor_uri(_), do: nil

  defp maybe_put_reaction_actor_uri(params, nil), do: params

  defp maybe_put_reaction_actor_uri(params, actor_uri),
    do: Map.put(params, "actor_uri", actor_uri)

  defp reaction_key_for_post_id(post_id) when is_integer(post_id), do: post_id

  defp reaction_key_for_post_id(post_id) when is_binary(post_id) do
    case Integer.parse(post_id) do
      {id, ""} -> id
      _ -> post_id
    end
  end

  defp reaction_key_for_post_id(post_id), do: post_id

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

  defp update_user_like_status(socket, message_id, liked) do
    assign(socket, :user_likes, Map.put(socket.assigns.user_likes, message_id, liked))
  end

  defp update_user_downvote_status(socket, message_id, downvoted) do
    assign(socket, :user_downvotes, Map.put(socket.assigns.user_downvotes, message_id, downvoted))
  end

  defp update_post_interaction(socket, message_id, :liked, liked, delta) do
    post = Enum.find(socket.assigns.timeline_posts || [], fn p -> p.id == message_id end)

    key =
      if post && post.activitypub_id do
        post.activitypub_id
      else
        to_string(message_id)
      end

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

    key =
      if post && post.activitypub_id do
        post.activitypub_id
      else
        to_string(message_id)
      end

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

  defp update_lemmy_score(socket, _message_id, delta) when delta == 0, do: socket

  defp update_lemmy_score(socket, message_id, delta) do
    case interaction_message_activitypub_id(socket, message_id) do
      nil ->
        socket

      activitypub_id ->
        lemmy_counts = Map.get(socket.assigns, :lemmy_counts, %{})

        case Map.fetch(lemmy_counts, activitypub_id) do
          {:ok, counts} when is_map(counts) ->
            updated_counts =
              counts
              |> Map.update(:score, max(delta, 0), &max((&1 || 0) + delta, 0))

            assign(socket, :lemmy_counts, Map.put(lemmy_counts, activitypub_id, updated_counts))

          _ ->
            socket
        end
    end
  end

  defp interaction_message_activitypub_id(socket, message_id) do
    message =
      Enum.find(socket.assigns.timeline_posts || [], &(&1.id == message_id)) ||
        socket.assigns.post_replies
        |> Kernel.||(%{})
        |> Map.values()
        |> List.flatten()
        |> Enum.find(&(&1.id == message_id))

    case message do
      %{activitypub_id: activitypub_id} when is_binary(activitypub_id) and activitypub_id != "" ->
        activitypub_id

      _ ->
        nil
    end
  end
end
