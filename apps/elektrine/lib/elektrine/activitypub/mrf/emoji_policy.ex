defmodule Elektrine.ActivityPub.MRF.EmojiPolicy do
  @moduledoc """
  Removes, rejects, or delists activities based on custom emoji names/URLs.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  alias Elektrine.ActivityPub.MRF.Utils

  @impl true
  def filter(%{"type" => "EmojiReact"} = activity) do
    config = Application.get_env(:elektrine, :mrf_emoji, [])

    if emoji_matches?(activity, config[:remove_url] || [], config[:remove_shortcode] || []) do
      {:reject, "[EmojiPolicy] rejected emoji reaction"}
    else
      {:ok, activity}
    end
  end

  def filter(%{"type" => type, "object" => object} = activity)
      when type in ["Create", "Update"] and is_map(object) do
    config = Application.get_env(:elektrine, :mrf_emoji, [])

    object =
      object
      |> remove_matching(:url, config[:remove_url] || [])
      |> remove_matching(:shortcode, config[:remove_shortcode] || [])

    activity = Map.put(activity, "object", object)

    if type == "Create" and
         emoji_matches?(
           object,
           config[:federated_timeline_removal_url] || [],
           config[:federated_timeline_removal_shortcode] || []
         ) do
      {:ok, Utils.delist(activity)}
    else
      {:ok, activity}
    end
  end

  def filter(%{"type" => type} = actor)
      when type in ["Person", "Group", "Application", "Service", "Organization"] do
    config = Application.get_env(:elektrine, :mrf_emoji, [])

    {:ok,
     actor
     |> remove_matching(:url, config[:remove_url] || [])
     |> remove_matching(:shortcode, config[:remove_shortcode] || [])}
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    {:ok, %{mrf_emoji: Application.get_env(:elektrine, :mrf_emoji, []) |> Map.new()}}
  end

  defp remove_matching(object, kind, patterns) do
    tags =
      object
      |> Map.get("tag", [])
      |> List.wrap()
      |> Enum.reject(fn
        %{"type" => "Emoji"} = tag -> Utils.matches_any?(emoji_value(tag, kind), patterns)
        _ -> false
      end)

    emoji =
      object
      |> Map.get("emoji", %{})
      |> case do
        map when is_map(map) ->
          Enum.reject(map, fn {name, url} ->
            value = if kind == :url, do: to_string(url), else: String.trim(to_string(name), ":")
            Utils.matches_any?(value, patterns)
          end)
          |> Map.new()

        other ->
          other
      end

    object
    |> Map.put("tag", tags)
    |> Map.put("emoji", emoji)
  end

  defp emoji_matches?(object, url_patterns, shortcode_patterns) do
    Enum.any?(Utils.emoji_tags(object), fn tag ->
      Utils.matches_any?(emoji_value(tag, :url), url_patterns) or
        Utils.matches_any?(emoji_value(tag, :shortcode), shortcode_patterns)
    end)
  end

  defp emoji_value(%{"icon" => %{"url" => url}}, :url) when is_binary(url), do: url
  defp emoji_value(%{"url" => url}, :url) when is_binary(url), do: url
  defp emoji_value(%{"name" => name}, :shortcode) when is_binary(name), do: String.trim(name, ":")
  defp emoji_value(_tag, _kind), do: ""
end
