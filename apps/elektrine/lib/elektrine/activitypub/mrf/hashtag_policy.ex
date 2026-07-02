defmodule Elektrine.ActivityPub.MRF.HashtagPolicy do
  @moduledoc """
  Rejects, delists, or marks sensitive posts by hashtag.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  alias Elektrine.ActivityPub.MRF.Utils

  @impl true
  def filter(%{"type" => type, "object" => object} = activity)
      when type in ["Create", "Update"] and is_map(object) do
    hashtags = Utils.hashtags(object)
    config = Application.get_env(:elektrine, :mrf_hashtag, [])

    if intersects?(hashtags, Keyword.get(config, :reject, [])) do
      {:reject, "[HashtagPolicy] rejected hashtag"}
    else
      activity =
        activity
        |> maybe_delist(type, hashtags, Keyword.get(config, :federated_timeline_removal, []))
        |> maybe_sensitive(hashtags, Keyword.get(config, :sensitive, []))

      {:ok, activity}
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    {:ok, %{mrf_hashtag: Application.get_env(:elektrine, :mrf_hashtag, []) |> Map.new()}}
  end

  defp maybe_delist(activity, "Create", hashtags, patterns) do
    if intersects?(hashtags, patterns), do: Utils.delist(activity), else: activity
  end

  defp maybe_delist(activity, _type, _hashtags, _patterns), do: activity

  defp maybe_sensitive(%{"object" => object} = activity, hashtags, patterns) do
    if intersects?(hashtags, patterns) do
      Map.put(activity, "object", Map.put(object, "sensitive", true))
    else
      activity
    end
  end

  defp intersects?(hashtags, patterns) do
    normalized = Enum.map(patterns, &Utils.normalize_hashtag/1)
    Enum.any?(hashtags, &(&1 in normalized))
  end
end
