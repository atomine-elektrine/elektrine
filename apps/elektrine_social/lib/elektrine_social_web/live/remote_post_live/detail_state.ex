defmodule ElektrineSocialWeb.RemotePostLive.DetailState do
  @moduledoc false

  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.Social
  alias ElektrineWeb.Live.PostInteractions

  def detail_message_with_reply_count(message, replies, replies_loaded) when is_map(message) do
    resolved_count = length(replies)

    reply_count =
      if replies_loaded && !Map.get(message, :federated, false) do
        resolved_count
      else
        max(resolved_count, message.reply_count || 0)
      end

    %{message | reply_count: reply_count}
  end

  def detail_message_interaction(post_interactions, message) do
    message
    |> detail_message_keys()
    |> Enum.filter(& &1)
    |> Enum.map(&PostInteractions.normalize_key/1)
    |> Enum.find_value(fn key -> Map.get(post_interactions, key) end)
    |> case do
      nil ->
        %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

      state ->
        state
        |> Map.put_new(:liked, false)
        |> Map.put_new(:boosted, false)
        |> Map.put_new(:like_delta, 0)
        |> Map.put_new(:boost_delta, 0)
    end
  end

  def detail_message_reactions(post_reactions, message) do
    message
    |> detail_message_keys()
    |> Enum.find_value([], &Map.get(post_reactions, &1))
  end

  def merge_remote_post_reactions(post_reactions, _post_object, local_message)
      when not is_nil(local_message) do
    remove_remote_reaction_entries(post_reactions || %{}, local_message)
  end

  def merge_remote_post_reactions(post_reactions, post_object, local_message) do
    remote_reactions = remote_emoji_reaction_entries(post_object, local_message)

    if remote_reactions == [] do
      post_reactions || %{}
    else
      [
        field_value(post_object, ["id", :id]),
        field_value(post_object, ["url", :url]),
        field_value(local_message, [:activitypub_id, "activitypub_id"]),
        field_value(local_message, [:activitypub_url, "activitypub_url"]),
        field_value(local_message, [:id, "id"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&PostInteractions.normalize_key/1)
      |> Enum.uniq()
      |> Enum.reduce(post_reactions || %{}, fn key, acc ->
        Map.update(
          acc,
          key,
          remote_reactions,
          &merge_remote_reaction_entries(&1, remote_reactions)
        )
      end)
    end
  end

  def misskey_emoji_reactions(reactions) when is_map(reactions) do
    reactions
    |> Enum.map(fn {emoji, count} ->
      %{"name" => emoji, "count" => normalize_display_count(count)}
    end)
    |> Enum.filter(&(&1["count"] > 0))
  end

  def misskey_emoji_reactions(_), do: []

  def detail_message_saved?(user_saves, message) do
    message
    |> detail_message_keys()
    |> Enum.any?(&Map.get(user_saves, &1, false))
  end

  def detail_message_save_map(user_saves, message) when is_map(user_saves) do
    saved? = detail_message_saved?(user_saves, message)

    message
    |> detail_message_keys()
    |> Enum.reduce(user_saves, fn key, acc ->
      Map.put(acc, key, saved?)
    end)
  end

  def detail_message_save_map(_, message) do
    message
    |> detail_message_keys()
    |> Enum.reduce(%{}, fn key, acc ->
      Map.put(acc, key, false)
    end)
  end

  def detail_message_keys(message) do
    [
      field_value(message, [:id, "id"]),
      field_value(message, [:activitypub_id, "activitypub_id"]),
      field_value(message, [:activitypub_url, "activitypub_url"])
    ]
    |> Enum.filter(& &1)
    |> Enum.map(&PostInteractions.normalize_key/1)
    |> Enum.uniq()
  end

  def main_post_interaction_state(post_interactions, post, local_message)
      when is_map(post_interactions) do
    [
      local_message && local_message.id,
      local_message && local_message.activitypub_id,
      local_message && local_message.activitypub_url,
      post && post["id"],
      post && post["url"]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&PostInteractions.normalize_key/1)
    |> Enum.find_value(%{liked: false, boosted: false, like_delta: 0, boost_delta: 0}, fn key ->
      Map.get(post_interactions, key)
    end)
  end

  def main_post_interaction_state(_, _post, _local_message),
    do: %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

  def load_detail_post_interactions(post_object, local_message, user_id) do
    shared_message = shared_detail_message(local_message)

    lookup_posts =
      [
        post_object,
        local_message && %{"id" => local_message.activitypub_id},
        local_message && %{"id" => local_message.activitypub_url},
        shared_message && %{"id" => shared_message.activitypub_id},
        shared_message && %{"id" => shared_message.activitypub_url}
      ]
      |> Enum.reject(fn
        %{"id" => id} -> !Elektrine.Strings.present?(id)
        value -> is_nil(value)
      end)
      |> Enum.uniq_by(& &1["id"])

    interactions = APHelpers.load_post_interactions(lookup_posts, user_id)
    state = main_post_interaction_state(interactions, post_object, local_message)

    interactions =
      detail_post_keys(post_object, local_message)
      |> Enum.reduce(interactions, fn key, acc -> Map.put(acc, key, state) end)

    if shared_message do
      shared_state = main_post_interaction_state(interactions, nil, shared_message)

      nil
      |> detail_post_keys(shared_message)
      |> Enum.reduce(interactions, fn key, acc -> Map.put(acc, key, shared_state) end)
    else
      interactions
    end
  end

  def load_local_detail_user_state(user_id, local_message, post_interactions, user_saves) do
    [local_message, shared_detail_message(local_message)]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce({post_interactions || %{}, user_saves || %{}}, fn message,
                                                                     {interactions_acc, saves_acc} ->
      state = %{
        liked: Social.user_liked_post?(user_id, message.id),
        boosted: Social.user_boosted?(user_id, message.id),
        like_delta: 0,
        boost_delta: 0
      }

      saved = Social.post_saved?(user_id, message.id)
      keys = detail_message_keys(message)

      {
        Enum.reduce(keys, interactions_acc, &Map.put(&2, &1, state)),
        Enum.reduce(keys, saves_acc, &Map.put(&2, &1, saved))
      }
    end)
  end

  def detail_post_keys(post_object, local_message) do
    [
      field_value(post_object, ["id", :id]),
      field_value(post_object, ["url", :url]),
      field_value(local_message, [:activitypub_id, "activitypub_id"]),
      field_value(local_message, [:activitypub_url, "activitypub_url"]),
      field_value(local_message, [:id, "id"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&PostInteractions.normalize_key/1)
    |> Enum.uniq()
  end

  def reset_main_post_vote_delta(post_interactions, post, local_message)
      when is_map(post_interactions) do
    post
    |> detail_post_keys(local_message)
    |> Enum.reduce(post_interactions, fn key, acc ->
      if Map.has_key?(acc, key) do
        Map.update!(acc, key, fn state ->
          state
          |> Map.put(:vote_delta, 0)
          |> Map.put(:like_delta, 0)
          |> Map.put(:boost_delta, 0)
        end)
      else
        acc
      end
    end)
  end

  def reset_main_post_vote_delta(post_interactions, _post, _local_message), do: post_interactions

  defp remote_emoji_reaction_entries(post_object, local_message) do
    metadata = field_value(local_message, [:media_metadata, "media_metadata"]) || %{}

    [
      field_value(post_object, ["emoji_reactions", :emoji_reactions]),
      field_value(metadata, ["emoji_reactions", :emoji_reactions])
    ]
    |> Enum.flat_map(&normalize_remote_emoji_reactions/1)
    |> Enum.uniq_by(& &1.emoji)
  end

  defp normalize_remote_emoji_reactions(reactions) when is_list(reactions) do
    reactions
    |> Enum.map(&normalize_remote_emoji_reaction/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_remote_emoji_reactions(_), do: []

  defp normalize_remote_emoji_reaction(%{} = reaction) do
    emoji =
      reaction["name"] || reaction[:name] || reaction["emoji"] || reaction[:emoji] ||
        reaction["shortcode"] || reaction[:shortcode]

    count = normalize_display_count(reaction["count"] || reaction[:count] || 1)

    if Elektrine.Strings.present?(emoji) && count > 0 do
      %{
        emoji: emoji,
        remote_count: count,
        remote_reaction?: true,
        user_id: nil,
        user: nil,
        remote_actor: nil
      }
    end
  end

  defp normalize_remote_emoji_reaction([emoji, count]) do
    normalize_remote_emoji_reaction(%{"name" => emoji, "count" => count})
  end

  defp normalize_remote_emoji_reaction(_), do: nil

  defp merge_remote_reaction_entries(existing_reactions, remote_reactions)
       when is_list(existing_reactions) do
    existing_reactions
    |> Enum.reject(&(is_map(&1) && Map.get(&1, :remote_reaction?) == true))
    |> Kernel.++(remote_reactions)
  end

  defp merge_remote_reaction_entries(_existing_reactions, remote_reactions), do: remote_reactions

  defp remove_remote_reaction_entries(post_reactions, local_message) do
    [
      field_value(local_message, [:activitypub_id, "activitypub_id"]),
      field_value(local_message, [:activitypub_url, "activitypub_url"]),
      field_value(local_message, [:id, "id"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&PostInteractions.normalize_key/1)
    |> Enum.reduce(post_reactions, fn key, acc ->
      Map.update(acc, key, [], fn reactions ->
        reactions
        |> List.wrap()
        |> Enum.reject(&(is_map(&1) && Map.get(&1, :remote_reaction?) == true))
      end)
    end)
  end

  defp shared_detail_message(%{shared_message: shared_message}) do
    if loaded_assoc?(shared_message) && is_map(shared_message), do: shared_message
  end

  defp shared_detail_message(_), do: nil

  defp loaded_assoc?(%Ecto.Association.NotLoaded{}), do: false
  defp loaded_assoc?(nil), do: false
  defp loaded_assoc?(_), do: true

  defp field_value(nil, _keys), do: nil

  defp field_value(value, keys) when is_list(keys) do
    Enum.find_value(keys, fn key -> field_value(value, key) end)
  end

  defp field_value(%_{} = value, key) when is_atom(key), do: Map.get(value, key)
  defp field_value(%{} = value, key), do: Map.get(value, key)
  defp field_value(_, _), do: nil

  defp normalize_display_count(value) when is_integer(value), do: max(value, 0)

  defp normalize_display_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> max(parsed, 0)
      :error -> 0
    end
  end

  defp normalize_display_count(_), do: 0
end
