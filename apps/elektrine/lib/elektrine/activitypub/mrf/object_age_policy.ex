defmodule Elektrine.ActivityPub.MRF.ObjectAgePolicy do
  @moduledoc """
  MRF policy for filtering objects based on their age.

  This prevents old/backdated content from being imported, which can be used
  for spam or to fill timelines with old content.

  ## Configuration

  Configure in runtime.exs or config.exs:

      config :elektrine, :mrf_object_age,
        # Maximum age in seconds before action is taken
        threshold: 604800,  # 7 days
        # Actions: :reject, :delist, or :mark_sensitive
        actions: [:delist]

  ## Actions

  - `:reject` - Block the activity entirely
  - `:delist` - Remove from public timelines
  - `:mark_sensitive` - Mark as sensitive content
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  require Logger

  # 7 days in seconds
  @default_threshold 604_800
  @default_actions [:delist]

  @impl true
  def filter(%{"type" => "Create", "object" => object} = activity) when is_map(object) do
    case get_object_age(object) do
      {:ok, age_seconds} ->
        config = get_config()
        threshold = config[:threshold] || @default_threshold
        actions = config[:actions] || @default_actions

        if age_seconds > threshold do
          apply_actions(activity, object, actions, age_seconds, threshold)
        else
          {:ok, activity}
        end

      :error ->
        # Can't determine age, let it through
        {:ok, activity}
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    config = get_config()

    %{
      mrf_object_age: %{
        threshold: config[:threshold] || @default_threshold,
        actions: config[:actions] || @default_actions
      }
    }
  end

  defp get_object_age(object) do
    with published when is_binary(published) <- object["published"],
         {:ok, datetime, _offset} <- DateTime.from_iso8601(published) do
      age = DateTime.diff(DateTime.utc_now(), datetime, :second)
      {:ok, max(0, age)}
    else
      _ -> :error
    end
  end

  defp apply_actions(activity, object, actions, age_seconds, threshold) do
    age_days = Float.round(age_seconds / 86_400, 1)
    threshold_days = Float.round(threshold / 86_400, 1)

    cond do
      :reject in actions ->
        Logger.info(
          "ObjectAgePolicy: Rejecting #{age_days} day old activity (threshold: #{threshold_days} days)"
        )

        {:reject, "Object too old (#{age_days} days)"}

      :delist in actions or :mark_sensitive in actions ->
        Logger.info(
          "ObjectAgePolicy: Modifying #{age_days} day old activity (threshold: #{threshold_days} days)"
        )

        object =
          object
          |> maybe_delist(actions)
          |> maybe_mark_sensitive(actions)

        {:ok, Map.put(activity, "object", object)}

      true ->
        {:ok, activity}
    end
  end

  defp maybe_delist(object, actions) do
    if :delist in actions do
      Map.put(object, "_mrf_federated_timeline_removal", true)
    else
      object
    end
  end

  defp maybe_mark_sensitive(object, actions) do
    if :mark_sensitive in actions do
      Map.put(object, "sensitive", true)
    else
      object
    end
  end

  defp get_config do
    Application.get_env(:elektrine, :mrf_object_age, [])
  end
end
