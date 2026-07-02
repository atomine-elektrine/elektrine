defmodule Elektrine.Social.FeedPolicy do
  @moduledoc """
  First-class per-viewer timeline policy shared by queries, cache fanout, and rendering.
  """

  import Ecto.Query

  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo

  alias Elektrine.Social.{
    Filters,
    HashtagFollow,
    Message,
    MessagePolicy,
    PostHashtag,
    TimelineRelationships
  }

  def filter_home_posts(user_id, posts, opts \\ [])

  def filter_home_posts(nil, posts, _opts), do: posts

  def filter_home_posts(user_id, posts, opts) when is_integer(user_id) and is_list(posts) do
    relationships = TimelineRelationships.load(user_id, posts)

    Enum.filter(posts, fn post ->
      visible_in_home?(user_id, post, opts, relationships)
    end)
  end

  def visible_in_home?(user_id, message, opts \\ [])

  def visible_in_home?(user_id, %Message{} = message, opts) when is_integer(user_id) do
    relationships = TimelineRelationships.load(user_id, [message])
    visible_in_home?(user_id, message, opts, relationships)
  end

  def visible_in_home?(_user_id, _message, _opts), do: false

  def visible_for_notification?(user_id, message, opts \\ [])

  def visible_for_notification?(user_id, %Message{} = message, opts)
      when is_integer(user_id) do
    relationships = TimelineRelationships.load(user_id, [message])

    not deleted_or_draft?(message) and
      approved?(message) and
      not MapSet.member?(relationships.blocked_message_ids, message.id) and
      MessagePolicy.visible?(user_id, message) and
      not hidden_by_viewer_preference?(message, opts) and
      not Filters.filtered?(user_id, message, Keyword.get(opts, :context, :notifications)) and
      not filtered_by_keywords?(message, Keyword.get(opts, :keyword_filters, [])) and
      not filtered_by_community?(message, Keyword.get(opts, :blocked_community_uris, []))
  end

  def visible_for_notification?(_user_id, _message, _opts), do: false

  defp visible_in_home?(user_id, %Message{} = message, opts, relationships) do
    not deleted_or_draft?(message) and
      approved?(message) and
      not MapSet.member?(relationships.blocked_message_ids, message.id) and
      MessagePolicy.visible?(user_id, message) and
      home_scope_allowed?(user_id, message) and
      not hidden_by_viewer_preference?(message, opts) and
      not Filters.filtered?(user_id, message, Keyword.get(opts, :context, :home)) and
      not filtered_by_keywords?(message, Keyword.get(opts, :keyword_filters, [])) and
      not filtered_by_community?(message, Keyword.get(opts, :blocked_community_uris, []))
  end

  defp deleted_or_draft?(message), do: not is_nil(message.deleted_at) or message.is_draft == true

  defp approved?(%{approval_status: status}), do: status in [nil, "approved"]

  defp home_scope_allowed?(user_id, %{sender_id: user_id}), do: true

  defp home_scope_allowed?(user_id, %{sender_id: sender_id, id: message_id})
       when is_integer(sender_id),
       do:
         Profiles.following?(user_id, sender_id) or follows_message_hashtag?(user_id, message_id)

  defp home_scope_allowed?(user_id, %{remote_actor_id: actor_id, id: message_id})
       when is_integer(actor_id) do
    following_remote_actor?(user_id, actor_id) or follows_message_hashtag?(user_id, message_id)
  end

  defp home_scope_allowed?(user_id, %{id: message_id}) when is_integer(message_id) do
    follows_message_hashtag?(user_id, message_id)
  end

  defp home_scope_allowed?(_user_id, _message), do: false

  defp following_remote_actor?(user_id, actor_id) do
    Repo.exists?(
      from f in Follow,
        where:
          f.follower_id == ^user_id and f.remote_actor_id == ^actor_id and
            f.pending == false
    )
  end

  defp follows_message_hashtag?(user_id, message_id)
       when is_integer(user_id) and is_integer(message_id) do
    Repo.exists?(
      from ph in PostHashtag,
        join: hf in HashtagFollow,
        on: hf.hashtag_id == ph.hashtag_id,
        where: ph.message_id == ^message_id and hf.user_id == ^user_id
    )
  end

  defp follows_message_hashtag?(_user_id, _message_id), do: false

  defp hidden_by_viewer_preference?(message, opts) do
    (Keyword.get(opts, :hide_boosts, false) and boost?(message)) or
      (Keyword.get(opts, :hide_replies, false) and reply?(message)) or
      (Keyword.get(opts, :hide_media, false) and media?(message)) or
      (Keyword.get(opts, :hide_sensitive, false) and sensitive?(message))
  end

  defp boost?(%{post_type: "share"}), do: true
  defp boost?(%{shared_message_id: id}) when is_integer(id), do: true
  defp boost?(_message), do: false

  defp reply?(%{reply_to_id: id}) when is_integer(id), do: true
  defp reply?(%{media_metadata: %{"inReplyTo" => value}}) when not is_nil(value), do: true
  defp reply?(%{media_metadata: %{inReplyTo: value}}) when not is_nil(value), do: true
  defp reply?(_message), do: false

  defp media?(%{media_urls: media_urls}) when is_list(media_urls), do: media_urls != []
  defp media?(_message), do: false

  defp sensitive?(%{sensitive: true}), do: true

  defp sensitive?(%{content_warning: warning}) when is_binary(warning),
    do: String.trim(warning) != ""

  defp sensitive?(_message), do: false

  defp filtered_by_keywords?(_message, []), do: false

  defp filtered_by_keywords?(message, filters) do
    haystack =
      [message.title, message.content, message.content_warning]
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")
      |> String.downcase()

    filters
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase(String.trim(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.any?(&String.contains?(haystack, &1))
  end

  defp filtered_by_community?(_message, []), do: false

  defp filtered_by_community?(%{media_metadata: metadata}, blocked_uris) when is_map(metadata) do
    community_uri = metadata["community_actor_uri"] || metadata[:community_actor_uri]
    is_binary(community_uri) and community_uri in blocked_uris
  end

  defp filtered_by_community?(_message, _blocked_uris), do: false
end
