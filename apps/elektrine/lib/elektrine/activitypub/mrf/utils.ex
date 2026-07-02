defmodule Elektrine.ActivityPub.MRF.Utils do
  @moduledoc false

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  def public_uri, do: @public_uri

  def status_object?(%{"type" => type}) do
    type in ["Note", "Article", "Page", "Question", "Event", "Audio", "Video", "Image"]
  end

  def create_or_update?(%{"type" => type}), do: type in ["Create", "Update"]
  def create_or_update?(_), do: false

  def local_actor?(actor) when is_binary(actor) do
    String.starts_with?(actor, Elektrine.ActivityPub.instance_url())
  end

  def local_actor?(_), do: false

  def recipients(value) when is_list(value), do: value
  def recipients(value) when is_binary(value), do: [value]
  def recipients(_), do: []

  def mention_recipients(activity) do
    actor = activity["actor"] || get_in(activity, ["object", "actor"])
    followers = if is_binary(actor), do: actor <> "/followers", else: nil

    activity_recipients =
      recipients(activity["to"]) ++ recipients(activity["cc"])

    object_recipients =
      case activity["object"] do
        object when is_map(object) -> recipients(object["to"]) ++ recipients(object["cc"])
        _ -> []
      end

    (activity_recipients ++ object_recipients)
    |> Enum.reject(&(&1 in [@public_uri, followers, nil]))
    |> Enum.uniq()
  end

  def visibility(%{"actor" => actor} = activity) when is_binary(actor) do
    to = recipients(activity["to"])
    cc = recipients(activity["cc"])
    followers = actor <> "/followers"

    cond do
      @public_uri in to -> "public"
      @public_uri in cc -> "unlisted"
      followers in to -> "followers"
      true -> "direct"
    end
  end

  def visibility(_activity), do: "direct"

  def delist(activity) do
    update_visibility_targets(activity, fn to, cc ->
      {List.delete(to, @public_uri), Enum.uniq([@public_uri | cc])}
    end)
  end

  def quiet_reply(%{"actor" => actor} = activity) when is_binary(actor) do
    followers = actor <> "/followers"

    update_visibility_targets(activity, fn to, cc ->
      {
        [followers | to] |> List.delete(@public_uri) |> Enum.uniq(),
        [@public_uri | cc] |> List.delete(followers) |> Enum.uniq()
      }
    end)
  end

  def quiet_reply(activity), do: activity

  def update_visibility_targets(%{"object" => object} = activity, updater) when is_map(object) do
    activity
    |> update_targets(updater)
    |> Map.put("object", update_targets(object, updater))
  end

  def update_visibility_targets(activity, updater), do: update_targets(activity, updater)

  def update_targets(value, updater) when is_map(value) do
    to = recipients(value["to"])
    cc = recipients(value["cc"])
    {updated_to, updated_cc} = updater.(to, cc)

    value
    |> Map.put("to", updated_to)
    |> Map.put("cc", updated_cc)
  end

  def update_targets(value, _updater), do: value

  def hashtags(value) when is_map(value) do
    tag_hashtags =
      value
      |> Map.get("tag", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"type" => "Hashtag", "name" => name} when is_binary(name) -> [normalize_hashtag(name)]
        %{"type" => "Hashtag", "href" => href} when is_binary(href) -> [normalize_hashtag(href)]
        _ -> []
      end)

    extracted =
      value
      |> Map.get("content", "")
      |> strip_html()
      |> then(&Regex.scan(~r/(?:^|\s)#([\p{L}\p{N}_-]+)/u, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.map(&normalize_hashtag/1)

    (tag_hashtags ++ extracted)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def hashtags(_), do: []

  def emoji_tags(value) when is_map(value) do
    tags =
      value
      |> Map.get("tag", [])
      |> List.wrap()
      |> Enum.filter(&match?(%{"type" => "Emoji"}, &1))

    emoji_map =
      value
      |> Map.get("emoji", %{})
      |> case do
        map when is_map(map) ->
          Enum.map(map, fn {name, url} ->
            %{
              "type" => "Emoji",
              "name" => ":" <> String.trim(to_string(name), ":") <> ":",
              "icon" => %{"url" => url}
            }
          end)

        _ ->
          []
      end

    tags ++ emoji_map
  end

  def emoji_tags(_), do: []

  def strip_html(value) when is_binary(value) do
    value
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def strip_html(_), do: ""

  def matches_any?(value, patterns) when is_binary(value) and is_list(patterns) do
    Enum.any?(patterns, &matches?(value, &1))
  end

  def matches_any?(_value, _patterns), do: false

  def matches?(value, %Regex{} = pattern), do: Regex.match?(pattern, value)

  def matches?(value, pattern) when is_binary(pattern) do
    String.downcase(value) == String.downcase(pattern)
  end

  def matches?(_value, _pattern), do: false

  def normalize_hashtag(value) when is_binary(value) do
    value
    |> String.split("/")
    |> List.last()
    |> String.trim_leading("#")
    |> String.downcase()
  end

  def normalize_hashtag(_), do: ""
end
