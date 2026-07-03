defmodule ElektrineSocialWeb.RemoteUserLive.PostState do
  @moduledoc """
  Shared post-state helpers for the remote user profile LiveView.

  Resolves interaction/save/reply state for locally cached posts and remote
  outbox posts, and normalizes the various post id shapes the UI sends.
  """

  import Phoenix.Component

  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.Repo
  alias Elektrine.Social
  alias ElektrineSocialWeb.Components.Social.PostUtilities
  alias ElektrineWeb.Live.PostInteractions

  def current_user_missing?(socket), do: is_nil(socket.assigns[:current_user])

  def load_post_interactions(posts, user_id)
      when is_list(posts) and is_integer(user_id) do
    import Ecto.Query

    messages = messages_for_local_state(posts)
    message_ids = Enum.map(messages, & &1.id)

    if message_ids == [] do
      APHelpers.load_post_interactions(posts, user_id)
    else
      liked_ids =
        from(l in Elektrine.Social.PostLike,
          where: l.user_id == ^user_id and l.message_id in ^message_ids,
          select: l.message_id
        )
        |> Repo.all()
        |> MapSet.new()

      boosted_ids =
        from(b in Elektrine.Social.PostBoost,
          where: b.user_id == ^user_id and b.message_id in ^message_ids,
          select: b.message_id
        )
        |> Repo.all()
        |> MapSet.new()

      votes =
        from(v in Elektrine.Social.MessageVote,
          where: v.user_id == ^user_id and v.message_id in ^message_ids,
          select: {v.message_id, v.vote_type}
        )
        |> Repo.all()
        |> Map.new()

      Enum.reduce(messages, %{}, fn message, acc ->
        state = %{
          liked: MapSet.member?(liked_ids, message.id),
          boosted: MapSet.member?(boosted_ids, message.id),
          like_delta: 0,
          boost_delta: 0,
          vote: Map.get(votes, message.id),
          vote_delta: 0
        }

        message
        |> local_message_state_keys()
        |> Enum.reduce(acc, fn key, key_acc -> Map.put(key_acc, key, state) end)
      end)
    end
  end

  def load_post_interactions(posts, user_id),
    do: APHelpers.load_post_interactions(posts, user_id)

  def load_user_saves_for_posts(posts, user_id)
      when is_list(posts) and is_integer(user_id) do
    keyed_posts =
      posts
      |> messages_for_local_state()
      |> Enum.flat_map(fn post ->
        Enum.map(local_message_state_keys(post), fn key -> {key, post.id} end)
      end)

    message_ids =
      keyed_posts
      |> Enum.map(fn {_key, message_id} -> message_id end)
      |> Enum.uniq()

    saved_ids = Social.list_user_saved_posts(user_id, message_ids)

    Enum.into(keyed_posts, %{}, fn {key, message_id} ->
      {key, MapSet.member?(saved_ids, message_id)}
    end)
  end

  def load_user_saves_for_posts(_, _), do: %{}

  def messages_for_local_state(posts) when is_list(posts) do
    posts
    |> Enum.flat_map(fn
      %Elektrine.Social.Message{} = post -> [post, shared_message_for_state(post)]
      _ -> []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  def shared_message_for_state(%{shared_message: %Ecto.Association.NotLoaded{}}), do: nil

  def shared_message_for_state(%{shared_message: %Elektrine.Social.Message{} = shared_message}) do
    shared_message
  end

  def shared_message_for_state(_), do: nil

  def local_message_state_keys(%{id: id} = message) when is_integer(id) do
    [
      id,
      Integer.to_string(id),
      Map.get(message, :activitypub_id),
      Map.get(message, :activitypub_url)
    ]
    |> Enum.reject(&(is_nil(&1) || &1 == ""))
    |> Enum.uniq()
  end

  def local_message_state_keys(_), do: []

  def normalize_post_id_for_reply(socket, value) do
    decoded_value = decode_post_ref(value)

    case parse_local_message_id(decoded_value) do
      {:ok, id} ->
        case Enum.find(socket.assigns.local_posts || [], &(&1.id == id)) do
          %{activitypub_id: activitypub_id}
          when is_binary(activitypub_id) and activitypub_id != "" ->
            activitypub_id

          %{id: local_id} when is_integer(local_id) ->
            Integer.to_string(local_id)

          _ ->
            to_string(decoded_value)
        end

      :error ->
        to_string(decoded_value)
    end
  end

  def normalize_navigate_post_id(socket, value) do
    decoded_value = decode_post_ref(value)

    case parse_local_message_id(decoded_value) do
      {:ok, id} ->
        case Enum.find(socket.assigns.local_posts || [], &(&1.id == id)) do
          %{activitypub_id: activitypub_id}
          when is_binary(activitypub_id) and activitypub_id != "" ->
            activitypub_id

          _ ->
            Integer.to_string(id)
        end

      :error ->
        to_string(decoded_value)
    end
  end

  def parse_local_message_id(value) when is_integer(value), do: {:ok, value}

  def parse_local_message_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  def parse_local_message_id(_), do: :error

  def parse_non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value
  def parse_non_negative_int(value, _default) when is_integer(value) and value < 0, do: 0

  def parse_non_negative_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      {parsed, ""} when parsed < 0 -> 0
      _ -> default
    end
  end

  def parse_non_negative_int(_value, default), do: default

  def decode_post_ref(value) when is_binary(value) do
    trimmed = String.trim(value)

    try do
      URI.decode_www_form(trimmed)
    rescue
      ArgumentError -> trimmed
    end
  end

  def decode_post_ref(value), do: value

  def likes_by_local_id(posts, post_interactions) when is_list(posts) do
    Enum.reduce(posts, %{}, fn
      %{id: id} = post, acc when is_integer(id) ->
        state = interaction_state_for_local_post(post, post_interactions)
        Map.put(acc, id, Map.get(state, :liked, false))

      _, acc ->
        acc
    end)
  end

  def likes_by_local_id(_, _), do: %{}

  def boosts_by_local_id(posts, post_interactions) when is_list(posts) do
    Enum.reduce(posts, %{}, fn
      %{id: id} = post, acc when is_integer(id) ->
        state = interaction_state_for_local_post(post, post_interactions)
        Map.put(acc, id, Map.get(state, :boosted, false))

      _, acc ->
        acc
    end)
  end

  def boosts_by_local_id(_, _), do: %{}

  def saves_by_local_id(posts, user_saves) when is_list(posts) do
    Enum.reduce(posts, %{}, fn
      %{id: id} = post, acc when is_integer(id) ->
        Map.put(acc, id, post_saved?(post, user_saves))

      _, acc ->
        acc
    end)
  end

  def saves_by_local_id(_, _), do: %{}

  def replies_by_local_id(posts, post_replies) when is_list(posts) do
    Enum.reduce(posts, %{}, fn
      %{id: id} = post, acc when is_integer(id) ->
        Map.put(acc, id, replies_for_post(post, post_replies))

      _, acc ->
        acc
    end)
  end

  def replies_by_local_id(_, _), do: %{}

  def interaction_state_for_local_post(post, post_interactions) do
    key_candidates =
      (local_message_state_keys(post) ++
         (post |> shared_message_for_state() |> local_message_state_keys()))
      |> Enum.reject(&is_nil/1)

    Enum.find_value(key_candidates, PostInteractions.default_interaction_state(), fn key ->
      Map.get(post_interactions || %{}, key)
    end) || PostInteractions.default_interaction_state()
  end

  def local_visible_message_id(socket, raw_message_id) do
    with {:ok, message_id} <- parse_local_message_id(raw_message_id),
         %{} <- local_visible_post(socket, message_id) do
      {:ok, message_id}
    else
      _ -> :error
    end
  end

  def local_visible_post(socket, message_id) when is_integer(message_id) do
    Enum.find_value(socket.assigns.local_posts || [], fn post ->
      cond do
        post.id == message_id ->
          post

        match?(%{id: ^message_id}, shared_message_for_state(post)) ->
          shared_message_for_state(post)

        true ->
          nil
      end
    end)
  end

  def local_visible_post_state(socket, message_id) when is_integer(message_id) do
    case local_visible_post(socket, message_id) do
      nil -> PostInteractions.default_interaction_state()
      post -> interaction_state_for_local_post(post, socket.assigns.post_interactions)
    end
  end

  def local_visible_vote_post?(socket, message_id) when is_integer(message_id) do
    case local_visible_post(socket, message_id) do
      nil -> false
      post -> PostUtilities.lemmy_vote_post?(post)
    end
  end

  def update_local_visible_post(socket, message_id, updater) when is_function(updater, 1) do
    socket
    |> update(:local_posts, fn posts ->
      Enum.map(posts || [], fn post ->
        cond do
          post.id == message_id ->
            updater.(post)

          match?(%{id: ^message_id}, shared_message_for_state(post)) ->
            Map.put(post, :shared_message, updater.(shared_message_for_state(post)))

          true ->
            post
        end
      end)
    end)
    |> update(:modal_post, fn
      %{id: ^message_id} = post ->
        updater.(post)

      %{shared_message: %{id: ^message_id} = shared_message} = post ->
        Map.put(post, :shared_message, updater.(shared_message))

      post ->
        post
    end)
  end

  def adjust_local_visible_post_count(socket, message_id, field, delta)
      when field in [:like_count, :dislike_count, :share_count, :score, :upvotes, :downvotes] and
             is_integer(delta) do
    allow_negative = field in [:score]

    update_local_visible_post(socket, message_id, fn post ->
      current = Map.get(post, field, 0) || 0
      updated = current + delta
      Map.put(post, field, if(allow_negative, do: updated, else: max(updated, 0)))
    end)
  end

  def update_local_visible_interaction(socket, message_id, updater)
      when is_function(updater, 1) do
    case local_visible_post(socket, message_id) do
      nil ->
        socket

      post ->
        keys = local_message_state_keys(post)

        current = interaction_state_for_local_post(post, socket.assigns.post_interactions)
        updated = updater.(current)

        updated_map =
          Enum.reduce(keys, socket.assigns.post_interactions || %{}, fn key, acc ->
            Map.put(acc, key, updated)
          end)

        assign(socket, :post_interactions, updated_map)
    end
  end

  def update_local_visible_save(socket, message_id, saved) when is_boolean(saved) do
    case local_visible_post(socket, message_id) do
      nil ->
        socket

      post ->
        keys = local_message_state_keys(post)

        updated_map =
          Enum.reduce(keys, socket.assigns.user_saves || %{}, fn key, acc ->
            Map.put(acc, key, saved)
          end)

        assign(socket, :user_saves, updated_map)
    end
  end

  def post_saved?(post, user_saves) do
    key_candidates =
      (local_message_state_keys(post) ++
         (post |> shared_message_for_state() |> local_message_state_keys()))
      |> Enum.reject(&is_nil/1)

    Enum.find_value(key_candidates, false, fn key ->
      case Map.get(user_saves || %{}, key) do
        nil -> nil
        value -> value
      end
    end) || false
  end

  def interaction_state_for_remote_post(post, post_interactions) when is_map(post) do
    key_candidates =
      [
        post["id"],
        post[:id],
        post["_local_activitypub_id"],
        post[:_local_activitypub_id],
        post["_local_message_id"],
        post[:_local_message_id]
      ]
      |> Enum.reject(&is_nil/1)

    Enum.find_value(key_candidates, PostInteractions.default_interaction_state(), fn key ->
      Map.get(post_interactions || %{}, key) || Map.get(post_interactions || %{}, to_string(key))
    end) || PostInteractions.default_interaction_state()
  end

  def put_remote_post_interaction_state(post_interactions, interaction_key, message, state) do
    [interaction_key, message.activitypub_id, Integer.to_string(message.id), message.id]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce(post_interactions || %{}, fn key, acc ->
      Map.put(acc, key, state)
    end)
  end

  def replies_for_post(post, post_replies) do
    key_candidates =
      local_message_state_keys(post)
      |> Enum.reject(&is_nil/1)

    Enum.find_value(key_candidates, [], fn key ->
      case Map.get(post_replies || %{}, key) do
        nil -> nil
        value -> value
      end
    end) || []
  end
end
