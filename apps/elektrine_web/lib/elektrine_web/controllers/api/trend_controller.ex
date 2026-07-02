defmodule ElektrineWeb.API.TrendController do
  @moduledoc """
  API-compatible trend endpoints.
  """
  use ElektrineWeb, :controller

  import Ecto.Query

  alias Elektrine.Repo
  alias Elektrine.Social.{LinkPreview, Message}
  alias ElektrineWeb.API.StatusJSON
  alias ElektrineWeb.Platform.Integrations

  @default_limit 10
  @max_limit 20

  def tags(conn, params) do
    user = conn.assigns[:current_user]

    tags =
      [limit: parse_limit(params["limit"])]
      |> Integrations.social_trending_hashtags()
      |> Enum.map(&format_tag(&1, user))

    json(conn, tags)
  end

  def statuses(conn, params) do
    user = conn.assigns[:current_user]

    statuses =
      social().get_trending_timeline(limit: parse_limit(params["limit"]), user_id: user.id)
      |> StatusJSON.format_statuses(user.id)

    json(conn, statuses)
  end

  def links(conn, params) do
    user = conn.assigns[:current_user]
    limit = parse_limit(params["limit"])

    links =
      user.id
      |> trending_link_candidates(limit * 20)
      |> Enum.flat_map(&message_links/1)
      |> Enum.group_by(& &1.url)
      |> Enum.map(&format_link_trend/1)
      |> Enum.sort_by(fn link -> {-link[:history_uses], link[:url]} end)
      |> Enum.take(limit)
      |> Enum.map(&Map.delete(&1, :history_uses))

    json(conn, links)
  end

  defp format_tag(tag, user) do
    name = tag.normalized_name || normalize_tag_name(tag.name)

    %{
      name: name,
      url: ElektrineWeb.Endpoint.url() <> "/tags/" <> URI.encode(name),
      history: [
        %{
          day: today_unix_day(),
          uses: tag.use_count || 0,
          accounts: Integrations.social_count_hashtag_followers(name)
        }
      ],
      following: following?(user, name)
    }
  end

  defp following?(%{id: user_id}, name), do: Integrations.social_following_hashtag?(user_id, name)
  defp following?(_user, _name), do: false

  defp trending_link_candidates(user_id, limit) do
    seven_days_ago = DateTime.utc_now() |> DateTime.add(-7, :day)

    from(message in Message,
      left_join: preview in assoc(message, :link_preview),
      where:
        message.visibility in ["public", "unlisted"] and
          message.is_draft != true and
          is_nil(message.deleted_at) and
          is_nil(message.reply_to_id) and
          message.inserted_at > ^seven_days_ago and
          (not is_nil(message.primary_url) or not is_nil(preview.id) or
             fragment("array_length(?, 1) > 0", message.extracted_urls)),
      order_by: [
        desc:
          fragment(
            "COALESCE(?, 0) + COALESCE(?, 0) + COALESCE(?, 0)",
            message.like_count,
            message.reply_count,
            message.share_count
          ),
        desc: message.inserted_at
      ],
      limit: ^limit,
      preload: [:link_preview, :sender]
    )
    |> Repo.all()
    |> Enum.filter(&social().status_visible?(user_id, &1))
  end

  defp message_links(%Message{} = message) do
    urls =
      [message.primary_url, preview_url(message.link_preview) | List.wrap(message.extracted_urls)]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    Enum.map(urls, fn url ->
      %{url: url, message: message, preview: preview_for_url(message.link_preview, url)}
    end)
  end

  defp preview_url(%LinkPreview{url: url}), do: url
  defp preview_url(_preview), do: nil

  defp preview_for_url(%LinkPreview{url: url} = preview, url), do: preview
  defp preview_for_url(_preview, _url), do: nil

  defp format_link_trend({url, entries}) do
    preview = entries |> Enum.map(& &1.preview) |> Enum.reject(&is_nil/1) |> List.first()
    messages = Enum.map(entries, & &1.message)
    uses = length(messages)

    accounts =
      messages |> Enum.map(& &1.sender_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()

    %{
      url: url,
      title: preview_value(preview, :title) || url,
      description: preview_value(preview, :description) || "",
      type: "link",
      author_name: "",
      provider_name: preview_value(preview, :site_name) || host(url),
      provider_url: provider_url(url),
      html: "",
      width: 0,
      height: 0,
      image: preview_value(preview, :image_url),
      embed_url: "",
      blurhash: nil,
      history: [%{day: today_unix_day(), uses: uses, accounts: accounts}],
      history_uses: uses
    }
  end

  defp preview_value(%LinkPreview{} = preview, field), do: Map.get(preview, field)
  defp preview_value(_preview, _field), do: nil

  defp host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> ""
    end
  end

  defp provider_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        scheme <> "://" <> host

      _ ->
        ""
    end
  end

  defp normalize_tag_name(tag_name) when is_binary(tag_name) do
    tag_name
    |> String.trim()
    |> String.trim_leading("#")
    |> String.downcase()
  end

  defp normalize_tag_name(_tag_name), do: ""

  defp parse_limit(nil), do: @default_limit

  defp parse_limit(value) do
    value
    |> positive_id()
    |> case do
      nil -> @default_limit
      limit -> limit |> max(1) |> min(@max_limit)
    end
  end

  defp positive_id(value) when is_integer(value) and value > 0, do: value

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp positive_id(_value), do: nil

  defp today_unix_day do
    Date.utc_today()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
    |> Integer.to_string()
  end

  defp social, do: Module.concat([Elektrine, Social])
end
