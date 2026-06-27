defmodule ElektrineSocialWeb.Components.Social.TimelinePostCard do
  @moduledoc false

  def card_post_path(%{id: id}, "remote_profile") when is_integer(id),
    do: Elektrine.Paths.remote_post_path(id)

  def card_post_path(post, _source), do: card_post_path(post)

  def card_post_path(%{id: id, reply_to_id: reply_to_id, conversation: %{type: "timeline"}})
      when is_integer(id) and not is_nil(reply_to_id),
      do: Elektrine.Paths.remote_post_path(id)

  def card_post_path(%{id: id} = post) when is_integer(id), do: Elektrine.Paths.post_path(post)

  def card_post_path(%{activitypub_url: url}) when is_binary(url), do: external_post_url(url)

  def card_post_path(%{activitypub_id: url}) when is_binary(url), do: external_post_url(url)

  def card_post_path(post), do: Elektrine.Paths.post_path(post)

  def external_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  def external_url?(_), do: false

  def resolve_federated_title(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || %{}

    [
      Map.get(post, :title),
      Map.get(post, "title"),
      Map.get(metadata, "name"),
      Map.get(metadata, :name),
      Map.get(metadata, "title"),
      Map.get(metadata, :title)
    ]
    |> Enum.find_value(&normalize_post_title/1)
  end

  def resolve_federated_title(_), do: nil

  defp external_post_url(url) when is_binary(url), do: Elektrine.Paths.post_path_or_external(url)

  defp normalize_post_title(title) when is_binary(title) do
    title
    |> String.trim()
    |> Elektrine.Strings.present()
  end

  defp normalize_post_title(_), do: nil
end
