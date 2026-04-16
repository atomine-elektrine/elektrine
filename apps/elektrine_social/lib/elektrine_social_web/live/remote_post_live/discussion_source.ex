defmodule ElektrineSocialWeb.RemotePostLive.DiscussionSource do
  @moduledoc false

  alias Elektrine.ActivityPub.LemmyApi

  @public_audience_uris MapSet.new([
                          "Public",
                          "as:Public",
                          "https://www.w3.org/ns/activitystreams#Public"
                        ])
  @user_actor_path_markers [
    "/users/",
    "/user/",
    "/u/",
    "/@",
    "/profile/",
    "/profiles/",
    "/accounts/"
  ]
  @community_path_markers ["/c/", "/m/", "/community/", "/communities/", "/groups/", "/g/"]

  def remote_discussion_source(post_id, post_object, local_message) do
    cond do
      lemmy_discussion_source?(post_id, post_object, local_message) ->
        :lemmy

      Elektrine.ActivityPub.MastodonApi.count_api_compatible?(%{activitypub_id: post_id}) ->
        :mastodon

      true ->
        :activitypub
    end
  end

  def initial_comment_counts_required?(post_id, post_object, local_message) do
    remote_discussion_source(post_id, post_object, local_message) == :lemmy
  end

  def community_post_url?(url) when is_binary(url), do: LemmyApi.community_post_url?(url)
  def community_post_url?(_), do: false

  def community_uri_from_local_message(%{media_metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "community_actor_uri") || Map.get(metadata, :community_actor_uri) do
      uri when is_binary(uri) ->
        case String.trim(uri) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  def community_uri_from_local_message(%{conversation: %{remote_group_actor: %{uri: uri}}})
      when is_binary(uri) do
    case String.trim(uri) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def community_uri_from_local_message(%{
        conversation: %{federated_source: uri, is_federated_mirror: true}
      })
      when is_binary(uri) do
    case String.trim(uri) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def community_uri_from_local_message(_), do: nil

  def find_community_uri(post_object) when is_map(post_object) do
    [
      post_object["audience"],
      post_object["to"],
      post_object["cc"],
      post_object["context"]
    ]
    |> Enum.flat_map(&community_uri_candidates/1)
    |> Enum.find(&community_like_actor_uri?/1)
  end

  def find_community_uri(_), do: nil

  defp lemmy_discussion_source?(post_id, post_object, local_message) do
    community_post_url?(post_id || "") ||
      community_post_url?(field_value(post_object, ["id", :id]) || "") ||
      community_post_url?(field_value(post_object, ["url", :url]) || "") ||
      is_binary(find_community_uri(post_object)) ||
      is_binary(community_uri_from_local_message(local_message))
  end

  defp community_uri_candidates(nil), do: []
  defp community_uri_candidates(value) when is_binary(value), do: [String.trim(value)]
  defp community_uri_candidates(%{"id" => value}), do: community_uri_candidates(value)
  defp community_uri_candidates(%{"url" => value}), do: community_uri_candidates(value)
  defp community_uri_candidates(%{id: value}), do: community_uri_candidates(value)
  defp community_uri_candidates(%{url: value}), do: community_uri_candidates(value)

  defp community_uri_candidates(values) when is_list(values),
    do: Enum.flat_map(values, &community_uri_candidates/1)

  defp community_uri_candidates(_), do: []

  defp community_like_actor_uri?(uri) when is_binary(uri) do
    normalized = String.trim(uri)

    cond do
      normalized == "" -> false
      normalized == "https://www.w3.org/ns/activitystreams#Public" -> false
      MapSet.member?(@public_audience_uris, normalized) -> false
      collection_uri?(normalized) -> false
      String.contains?(normalized, ["/c/", "/m/", "/groups/", "/communities/", "/g/"]) -> true
      String.contains?(normalized, ["/users/", "/user/", "/u/", "/@"]) -> false
      not community_path_uri?(normalized) -> false
      true -> true
    end
  end

  defp community_like_actor_uri?(_), do: false

  defp collection_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) ->
        normalized = path |> String.downcase() |> String.trim_trailing("/")
        String.ends_with?(normalized, "/followers") || String.ends_with?(normalized, "/following")

      _ ->
        false
    end
  end

  defp collection_uri?(_), do: false

  defp community_path_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) ->
        path_downcased = String.downcase(path)

        Enum.any?(@community_path_markers, &String.contains?(path_downcased, &1)) &&
          !user_actor_uri?(uri)

      _ ->
        false
    end
  end

  defp community_path_uri?(_), do: false

  defp user_actor_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) ->
        downcased_path = String.downcase(path)
        Enum.any?(@user_actor_path_markers, &String.contains?(downcased_path, &1))

      _ ->
        false
    end
  end

  defp user_actor_uri?(_), do: false

  defp field_value(nil, _keys), do: nil

  defp field_value(value, keys) when is_list(keys),
    do: Enum.find_value(keys, fn key -> field_value(value, key) end)

  defp field_value(%_{} = value, key) when is_atom(key), do: Map.get(value, key)
  defp field_value(%{} = value, key), do: Map.get(value, key)
  defp field_value(_, _), do: nil
end
