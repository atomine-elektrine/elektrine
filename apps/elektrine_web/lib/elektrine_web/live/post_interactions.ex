defmodule ElektrineWeb.Live.PostInteractions do
  @moduledoc """
  Shared helpers for resolving post identifiers and updating interaction state.

  Different surfaces may pass either local numeric IDs or remote ActivityPub IDs.
  This module normalizes that behavior so LiveViews stay consistent.
  """

  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo

  @default_state %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

  def default_interaction_state, do: @default_state

  def interaction_state(post_interactions, key) when is_map(post_interactions) do
    Map.get(post_interactions, normalize_key(key), @default_state)
  end

  def interaction_state(_, _), do: @default_state

  def adjust_interaction(post_interactions, key, updater) when is_function(updater, 1) do
    normalized_key = normalize_key(key)
    state = interaction_state(post_interactions, normalized_key)
    Map.put(post_interactions, normalized_key, updater.(state))
  end

  def resolve_message_for_interaction(interaction_id, opts \\ []) do
    actor_uri = Keyword.get(opts, :actor_uri)

    cond do
      is_integer(interaction_id) ->
        fetch_local_message(interaction_id)

      is_binary(interaction_id) ->
        interaction_id
        |> String.trim()
        |> resolve_binary_interaction_id(actor_uri)

      true ->
        {:error, :not_found}
    end
  end

  def interaction_key(raw_id, %Message{} = message) do
    cond do
      is_integer(raw_id) ->
        Integer.to_string(raw_id)

      is_binary(raw_id) ->
        case Integer.parse(String.trim(raw_id)) do
          {id, ""} -> Integer.to_string(id)
          _ -> message.activitypub_id || Integer.to_string(message.id)
        end

      true ->
        message.activitypub_id || Integer.to_string(message.id)
    end
  end

  def update_post_reactions(post_reactions, post_key, reaction, action)
      when is_map(post_reactions) do
    key = normalize_key(post_key)
    current_reactions = Map.get(post_reactions, key, [])

    updated_reactions =
      case action do
        :add ->
          if Enum.any?(current_reactions, fn existing ->
               existing.emoji == reaction.emoji && existing.user_id == reaction.user_id
             end) do
            current_reactions
          else
            [reaction | current_reactions]
          end

        :remove ->
          Enum.reject(current_reactions, fn existing ->
            existing.emoji == reaction.emoji && existing.user_id == reaction.user_id
          end)
      end

    Map.put(post_reactions, key, updated_reactions)
  end

  def update_post_reactions(post_reactions, _post_key, _reaction, _action), do: post_reactions

  def normalize_key(key) when is_binary(key), do: key
  def normalize_key(key) when is_integer(key), do: Integer.to_string(key)
  def normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  def normalize_key(key), do: to_string(key)

  defp resolve_binary_interaction_id("", _actor_uri), do: {:error, :not_found}

  defp resolve_binary_interaction_id(interaction_id, actor_uri) do
    case Integer.parse(interaction_id) do
      {id, ""} ->
        fetch_local_message(id)

      _ ->
        case Messaging.get_message_by_activitypub_id(interaction_id) do
          %Message{} = message ->
            {:ok, message}

          nil ->
            fetch_remote_message(interaction_id, actor_uri)
        end
    end
  end

  defp fetch_local_message(id) do
    case Repo.get(Message, id) do
      %Message{} = message -> {:ok, message}
      nil -> {:error, :not_found}
    end
  end

  defp fetch_remote_message(interaction_id, nil),
    do: APHelpers.get_or_store_remote_post(interaction_id)

  defp fetch_remote_message(interaction_id, ""),
    do: APHelpers.get_or_store_remote_post(interaction_id)

  defp fetch_remote_message(interaction_id, actor_uri),
    do: APHelpers.get_or_store_remote_post(interaction_id, actor_uri)
end
