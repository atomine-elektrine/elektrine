defmodule Elektrine.ActivityPub.MRF.HellthreadPolicy do
  @moduledoc """
  MRF policy for filtering hellthreads (posts with excessive mentions).

  Hellthreads are posts that mention a large number of users, often used for spam
  or harassment. This policy limits the number of mentions allowed in a post.

  ## Configuration

  Configure in runtime.exs or config.exs:

      config :elektrine, :mrf_hellthread,
        # Maximum mentions before action is taken
        delist_threshold: 10,
        reject_threshold: 20

  ## Actions

  - Posts with mentions >= `delist_threshold` are removed from public timelines
  - Posts with mentions >= `reject_threshold` are rejected entirely
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  require Logger

  @default_delist_threshold 10
  @default_reject_threshold 20

  @impl true
  def filter(%{"type" => "Create", "object" => object} = activity) when is_map(object) do
    # Count mentions from both activity-level to/cc and object-level tags
    mention_count = count_mentions(activity, object)
    config = get_config()

    reject_threshold = config[:reject_threshold] || @default_reject_threshold
    delist_threshold = config[:delist_threshold] || @default_delist_threshold

    cond do
      mention_count >= reject_threshold ->
        Logger.info(
          "HellthreadPolicy: Rejecting activity with #{mention_count} mentions (threshold: #{reject_threshold})"
        )

        {:reject, "Too many mentions (#{mention_count})"}

      mention_count >= delist_threshold ->
        Logger.info(
          "HellthreadPolicy: Delisting activity with #{mention_count} mentions (threshold: #{delist_threshold})"
        )

        # Remove from public timelines
        object = Map.put(object, "_mrf_federated_timeline_removal", true)
        {:ok, Map.put(activity, "object", object)}

      true ->
        {:ok, activity}
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    config = get_config()

    {:ok,
     %{
       mrf_hellthread: %{
         delist_threshold: config[:delist_threshold] || @default_delist_threshold,
         reject_threshold: config[:reject_threshold] || @default_reject_threshold
       }
     }}
  end

  defp count_mentions(activity, object) do
    # Count recipients from activity-level to/cc fields
    # (this is where ActivityPub specifies delivery targets)
    activity_to_count = count_recipients(activity["to"])
    activity_cc_count = count_recipients(activity["cc"])

    # Also count recipients from object-level to/cc (some implementations use this)
    object_to_count = count_recipients(object["to"])
    object_cc_count = count_recipients(object["cc"])

    # Count Mention tags in the object
    tag_count = count_mention_tags(object["tag"])

    # Use the maximum of all counts
    # (different implementations put mentions in different places)
    max(
      activity_to_count + activity_cc_count,
      max(object_to_count + object_cc_count, tag_count)
    )
  end

  defp count_recipients(nil), do: 0

  defp count_recipients(recipients) when is_list(recipients) do
    # Don't count public addresses or followers collections
    recipients
    |> Enum.reject(fn uri ->
      public_address?(uri) || followers_collection?(uri)
    end)
    |> length()
  end

  defp count_recipients(_), do: 0

  defp count_mention_tags(nil), do: 0

  defp count_mention_tags(tags) when is_list(tags) do
    tags
    |> Enum.count(fn tag -> is_map(tag) && tag["type"] == "Mention" end)
  end

  defp count_mention_tags(_), do: 0

  defp public_address?(uri) when is_binary(uri) do
    uri in [
      "https://www.w3.org/ns/activitystreams#Public",
      "as:Public",
      "Public"
    ]
  end

  defp public_address?(_), do: false

  defp followers_collection?(uri) when is_binary(uri) do
    String.ends_with?(uri, "/followers")
  end

  defp followers_collection?(_), do: false

  defp get_config do
    Application.get_env(:elektrine, :mrf_hellthread, [])
  end
end
