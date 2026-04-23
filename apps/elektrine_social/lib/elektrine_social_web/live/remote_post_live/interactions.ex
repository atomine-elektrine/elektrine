defmodule ElektrineSocialWeb.RemotePostLive.Interactions do
  @moduledoc false

  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.Messaging.Reactions
  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Message
  alias Elektrine.Social.MessageReaction
  alias Elektrine.Social.Votes
  alias ElektrineWeb.Live.PostInteractions

  @default_state PostInteractions.default_interaction_state()

  def like_message(socket, message_id, opts \\ []) do
    if current_user_missing?(socket) do
      {:noreply,
       Phoenix.LiveView.put_flash(socket, :error, "You must be signed in to like posts")}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: remote_actor_uri(socket)
           ) do
        {:ok, message} ->
          case Social.like_post(socket.assigns.current_user.id, message.id) do
            {:ok, _like} ->
              key = PostInteractions.interaction_key(message_id, message)

              post_interactions =
                update_post_interactions(
                  socket.assigns.post_interactions,
                  key,
                  fn current_state ->
                    %{
                      liked: true,
                      boosted: Map.get(current_state, :boosted, false),
                      like_delta: 0,
                      boost_delta: Map.get(current_state, :boost_delta, 0)
                    }
                  end
                )

              fresh_message = Repo.get(Message, message.id)

              updated_socket =
                socket
                |> Phoenix.Component.assign(:post_interactions, post_interactions)
                |> maybe_run_like_delta(opts, message.id, 1)
                |> maybe_run_refresh(opts, fresh_message)

              {:noreply, updated_socket}

            {:error, _} ->
              {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to like post")}
          end

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to process post")}
      end
    end
  end

  def like_post(socket, post_id, opts \\ []) do
    if current_user_missing?(socket) do
      {:noreply,
       Phoenix.LiveView.put_flash(socket, :error, "You must be signed in to like posts")}
    else
      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: remote_actor_uri(socket)
           ) do
        {:ok, message} ->
          case Social.like_post(socket.assigns.current_user.id, message.id) do
            {:ok, _like} ->
              key = PostInteractions.interaction_key(post_id, message)

              post_interactions =
                update_post_interactions(
                  socket.assigns.post_interactions,
                  key,
                  fn current_state ->
                    %{
                      liked: true,
                      boosted: Map.get(current_state, :boosted, false),
                      like_delta: Map.get(current_state, :like_delta, 0) + 1,
                      boost_delta: Map.get(current_state, :boost_delta, 0)
                    }
                  end
                )

              fresh_message = Repo.get(Message, message.id)

              updated_socket =
                socket
                |> Phoenix.Component.assign(:post_interactions, post_interactions)
                |> maybe_run_refresh(opts, fresh_message)

              {:noreply, updated_socket}

            {:error, _} ->
              {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to like post")}
          end

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to process post")}
      end
    end
  end

  def unlike_message(socket, message_id, opts \\ []) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: remote_actor_uri(socket)
           ) do
        {:ok, message} ->
          case Social.unlike_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              key = PostInteractions.interaction_key(message_id, message)

              post_interactions =
                update_post_interactions(
                  socket.assigns.post_interactions,
                  key,
                  fn current_state ->
                    %{
                      liked: false,
                      boosted: Map.get(current_state, :boosted, false),
                      like_delta: 0,
                      boost_delta: Map.get(current_state, :boost_delta, 0)
                    }
                  end
                )

              fresh_message = Repo.get(Message, message.id)

              updated_socket =
                socket
                |> Phoenix.Component.assign(:post_interactions, post_interactions)
                |> maybe_run_like_delta(opts, message.id, -1)
                |> maybe_run_refresh(opts, fresh_message)

              {:noreply, updated_socket}

            {:error, _} ->
              {:noreply, socket}
          end

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  def unlike_post(socket, post_id, opts \\ []) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: remote_actor_uri(socket)
           ) do
        {:ok, message} ->
          key = PostInteractions.interaction_key(post_id, message)

          case Social.unlike_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              post_interactions =
                update_post_interactions(
                  socket.assigns.post_interactions,
                  key,
                  fn current_state ->
                    %{
                      liked: false,
                      boosted: Map.get(current_state, :boosted, false),
                      like_delta: Map.get(current_state, :like_delta, 0) - 1,
                      boost_delta: Map.get(current_state, :boost_delta, 0)
                    }
                  end
                )

              fresh_message = Repo.get(Message, message.id)

              updated_socket =
                socket
                |> Phoenix.Component.assign(:post_interactions, post_interactions)
                |> maybe_run_refresh(opts, fresh_message)

              {:noreply, updated_socket}

            {:error, _} ->
              {:noreply, socket}
          end

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  def boost_message(socket, message_id, opts \\ []) do
    if current_user_missing?(socket) do
      {:noreply,
       Phoenix.LiveView.put_flash(socket, :error, "You must be signed in to boost posts")}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: remote_actor_uri(socket)
           ) do
        {:ok, message} ->
          case Social.boost_post(socket.assigns.current_user.id, message.id) do
            {:ok, _boost} ->
              key = PostInteractions.interaction_key(message_id, message)

              post_interactions =
                update_post_interactions(
                  socket.assigns.post_interactions,
                  key,
                  fn current_state ->
                    %{
                      liked: Map.get(current_state, :liked, false),
                      boosted: true,
                      like_delta: Map.get(current_state, :like_delta, 0),
                      boost_delta: 0
                    }
                  end
                )

              fresh_message = Repo.get(Message, message.id)

              updated_socket =
                socket
                |> Phoenix.Component.assign(:post_interactions, post_interactions)
                |> maybe_run_share_delta(opts, message.id, 1)
                |> maybe_run_refresh(opts, fresh_message)
                |> Phoenix.LiveView.put_flash(:info, "Post boosted to your timeline!")

              {:noreply, updated_socket}

            {:error, :already_boosted} ->
              {:noreply,
               Phoenix.LiveView.put_flash(socket, :info, "You've already boosted this post")}

            {:error, _} ->
              {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to boost post")}
          end

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to process post")}
      end
    end
  end

  def boost_post(socket, post_id, opts \\ []) do
    if current_user_missing?(socket) do
      {:noreply,
       Phoenix.LiveView.put_flash(socket, :error, "You must be signed in to boost posts")}
    else
      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: remote_actor_uri(socket)
           ) do
        {:ok, message} ->
          case Social.boost_post(socket.assigns.current_user.id, message.id) do
            {:ok, _boost} ->
              key = PostInteractions.interaction_key(post_id, message)

              post_interactions =
                update_post_interactions(
                  socket.assigns.post_interactions,
                  key,
                  fn current_state ->
                    %{
                      liked: Map.get(current_state, :liked, false),
                      boosted: true,
                      like_delta: Map.get(current_state, :like_delta, 0),
                      boost_delta: Map.get(current_state, :boost_delta, 0) + 1
                    }
                  end
                )

              updated_socket =
                socket
                |> Phoenix.Component.assign(:post_interactions, post_interactions)
                |> maybe_run_share_delta(opts, post_id, 1)
                |> Phoenix.LiveView.put_flash(:info, "Post boosted to your timeline!")

              {:noreply, updated_socket}

            {:error, :already_boosted} ->
              {:noreply,
               Phoenix.LiveView.put_flash(socket, :info, "You've already boosted this post")}

            {:error, _} ->
              {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to boost post")}
          end

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to process post")}
      end
    end
  end

  def unboost_message(socket, message_id, opts \\ []) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: remote_actor_uri(socket)
           ) do
        {:ok, message} ->
          case Social.unboost_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              key = PostInteractions.interaction_key(message_id, message)

              post_interactions =
                update_post_interactions(
                  socket.assigns.post_interactions,
                  key,
                  fn current_state ->
                    %{
                      liked: Map.get(current_state, :liked, false),
                      boosted: false,
                      like_delta: Map.get(current_state, :like_delta, 0),
                      boost_delta: 0
                    }
                  end
                )

              fresh_message = Repo.get(Message, message.id)

              updated_socket =
                socket
                |> Phoenix.Component.assign(:post_interactions, post_interactions)
                |> maybe_run_share_delta(opts, message.id, -1)
                |> maybe_run_refresh(opts, fresh_message)

              {:noreply, updated_socket}

            {:error, _} ->
              {:noreply, socket}
          end

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  def unboost_post(socket, post_id, opts \\ []) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: remote_actor_uri(socket)
           ) do
        {:ok, message} ->
          case Social.unboost_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              key = PostInteractions.interaction_key(post_id, message)

              post_interactions =
                update_post_interactions(
                  socket.assigns.post_interactions,
                  key,
                  fn current_state ->
                    %{
                      liked: Map.get(current_state, :liked, false),
                      boosted: false,
                      like_delta: Map.get(current_state, :like_delta, 0),
                      boost_delta: Map.get(current_state, :boost_delta, 0) - 1
                    }
                  end
                )

              updated_socket =
                socket
                |> Phoenix.Component.assign(:post_interactions, post_interactions)
                |> maybe_run_share_delta(opts, post_id, -1)

              {:noreply, updated_socket}

            {:error, _} ->
              {:noreply, socket}
          end

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  def save_message(socket, message_id) do
    if current_user_missing?(socket) do
      {:noreply,
       Phoenix.LiveView.put_flash(socket, :error, "You must be signed in to save posts")}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: remote_actor_uri(socket)
           ) do
        {:ok, message} ->
          user_saves = Map.get(socket.assigns, :user_saves, %{})
          updated_user_saves = put_saved_state(user_saves, message_id, message, true)

          case Social.save_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              {:noreply,
               socket
               |> Phoenix.Component.assign(:user_saves, updated_user_saves)
               |> Phoenix.LiveView.put_flash(:info, "Saved")}

            {:error, _} ->
              {:noreply,
               socket
               |> Phoenix.Component.assign(:user_saves, updated_user_saves)
               |> Phoenix.LiveView.put_flash(:info, "Already saved")}
          end

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to save post")}
      end
    end
  end

  def unsave_message(socket, message_id) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: remote_actor_uri(socket)
           ) do
        {:ok, message} ->
          case Social.unsave_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              user_saves = Map.get(socket.assigns, :user_saves, %{})
              updated_user_saves = put_saved_state(user_saves, message_id, message, false)

              {:noreply,
               socket
               |> Phoenix.Component.assign(:user_saves, updated_user_saves)
               |> Phoenix.LiveView.put_flash(:info, "Removed from saved")}

            {:error, _} ->
              {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to unsave")}
          end

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  def vote_remote_target(socket, target_id, vote_type, opts \\ []) do
    label = Keyword.get(opts, :target_label, "post")

    if current_user_missing?(socket) do
      {:noreply, Phoenix.LiveView.put_flash(socket, :error, "You must be signed in to vote")}
    else
      case PostInteractions.resolve_message_for_interaction(target_id,
             actor_uri: remote_actor_uri(socket)
           ) do
        {:ok, message} ->
          user_id = socket.assigns.current_user.id
          interaction_key = PostInteractions.interaction_key(target_id, message)

          current_state =
            Map.get(socket.assigns.post_interactions, interaction_key, @default_state)

          current_vote = Map.get(current_state, :vote, nil)
          current_vote_delta = Map.get(current_state, :vote_delta, 0)
          new_vote = if current_vote == vote_type, do: nil, else: vote_type
          vote_delta_change = calculate_vote_delta_change(current_vote, new_vote)
          new_vote_delta = current_vote_delta + vote_delta_change

          result = Votes.vote_on_message(user_id, message.id, vote_type)

          case result do
            {:ok, _} ->
              fresh_message = Repo.get(Message, message.id)

              post_interactions =
                Map.put(socket.assigns.post_interactions, interaction_key, %{
                  liked: Map.get(current_state, :liked, false),
                  boosted: Map.get(current_state, :boosted, false),
                  like_delta: Map.get(current_state, :like_delta, 0),
                  boost_delta: Map.get(current_state, :boost_delta, 0),
                  vote: new_vote,
                  vote_delta: new_vote_delta
                })

              updated_socket =
                socket
                |> Phoenix.Component.assign(:post_interactions, post_interactions)
                |> maybe_run_refresh(opts, fresh_message)

              {:noreply, updated_socket}

            {:error, _} ->
              {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to vote")}
          end

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to process #{label}")}
      end
    end
  end

  def react_remote_post(socket, post_id, emoji) do
    if current_user_missing?(socket) do
      {:noreply, Phoenix.LiveView.put_flash(socket, :error, "You must be signed in to react")}
    else
      user_id = socket.assigns.current_user.id

      case APHelpers.get_or_store_remote_post(post_id) do
        {:ok, message} ->
          toggle_reaction(socket, message, post_id, user_id, emoji)

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to process remote post")}
      end
    end
  end

  def react_message(socket, message_id, emoji) do
    if current_user_missing?(socket) do
      {:noreply, Phoenix.LiveView.put_flash(socket, :error, "You must be signed in to react")}
    else
      user_id = socket.assigns.current_user.id

      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: remote_actor_uri(socket)
           ) do
        {:ok, message} ->
          key = PostInteractions.interaction_key(message_id, message)
          toggle_reaction(socket, message, key, user_id, emoji)

        {:error, _} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to process post")}
      end
    end
  end

  defp maybe_run_refresh(socket, opts, fresh_message) do
    case Keyword.get(opts, :on_refresh) do
      fun when is_function(fun, 2) -> fun.(socket, fresh_message)
      _ -> socket
    end
  end

  defp maybe_run_share_delta(socket, opts, post_id, delta) do
    case Keyword.get(opts, :on_share_delta) do
      fun when is_function(fun, 3) -> fun.(socket, post_id, delta)
      _ -> socket
    end
  end

  defp maybe_run_like_delta(socket, opts, post_id, delta) do
    case Keyword.get(opts, :on_like_delta) do
      fun when is_function(fun, 3) -> fun.(socket, post_id, delta)
      _ -> socket
    end
  end

  defp put_saved_state(user_saves, raw_id, message, saved?) when is_map(user_saves) do
    [raw_id, message.id, message.activitypub_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&PostInteractions.normalize_key/1)
    |> Enum.uniq()
    |> Enum.reduce(user_saves, fn key, acc ->
      Map.put(acc, key, saved?)
    end)
  end

  defp update_post_interactions(post_interactions, key, updater) when is_function(updater, 1) do
    current_state = Map.get(post_interactions, key, @default_state)
    Map.put(post_interactions, key, updater.(current_state))
  end

  defp toggle_reaction(socket, message, reaction_key, user_id, emoji) do
    existing_reaction =
      Repo.get_by(MessageReaction,
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
              reaction_key,
              %{emoji: emoji, user_id: user_id},
              :remove
            )

          {:noreply, Phoenix.Component.assign(socket, :post_reactions, updated_reactions)}

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
              reaction_key,
              reaction,
              :add
            )

          {:noreply, Phoenix.Component.assign(socket, :post_reactions, updated_reactions)}

        {:error, :rate_limited} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, "Slow down! You're reacting too fast")}

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  defp calculate_vote_delta_change(old_vote, new_vote) do
    vote_to_value(new_vote) - vote_to_value(old_vote)
  end

  defp vote_to_value("up"), do: 1
  defp vote_to_value("down"), do: -1
  defp vote_to_value(_), do: 0

  defp current_user_missing?(socket), do: is_nil(socket.assigns[:current_user])

  defp remote_actor_uri(socket),
    do: socket.assigns[:remote_actor] && socket.assigns.remote_actor.uri
end
