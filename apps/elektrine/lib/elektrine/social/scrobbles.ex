defmodule Elektrine.Social.Scrobbles do
  @moduledoc """
  Music listen/scrobble records for social API clients.
  """

  import Ecto.Query

  alias Elektrine.Accounts.User
  alias Elektrine.Repo
  alias Elektrine.Social.Scrobble

  @default_limit 20
  @max_limit 80

  def create_scrobble(%User{} = user, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("user_id", user.id)
      |> Map.put_new("visibility", "public")
      |> normalize_external_link_alias()

    %Scrobble{}
    |> Scrobble.changeset(attrs)
    |> Repo.insert()
  end

  def list_public_scrobbles(%User{id: user_id}, params \\ %{}) do
    limit = parse_limit(params["limit"] || params[:limit])

    Scrobble
    |> where([scrobble], scrobble.user_id == ^user_id)
    |> where([scrobble], scrobble.visibility in ["public", "unlisted"])
    |> maybe_max_id(params["max_id"] || params[:max_id])
    |> maybe_since_id(params["since_id"] || params[:since_id])
    |> order_by([scrobble], desc: scrobble.id)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload(:user)
  end

  defp maybe_max_id(query, nil), do: query
  defp maybe_max_id(query, ""), do: query

  defp maybe_max_id(query, value) do
    case parse_integer(value) do
      nil -> query
      id -> where(query, [scrobble], scrobble.id < ^id)
    end
  end

  defp maybe_since_id(query, nil), do: query
  defp maybe_since_id(query, ""), do: query

  defp maybe_since_id(query, value) do
    case parse_integer(value) do
      nil -> query
      id -> where(query, [scrobble], scrobble.id > ^id)
    end
  end

  defp parse_limit(value) do
    case parse_integer(value) do
      nil -> @default_limit
      limit -> limit |> max(1) |> min(@max_limit)
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp normalize_external_link_alias(%{"external_link" => _} = attrs), do: attrs

  defp normalize_external_link_alias(%{"externalLink" => external_link} = attrs),
    do: Map.put(attrs, "external_link", external_link)

  defp normalize_external_link_alias(attrs), do: attrs

  defp stringify_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
