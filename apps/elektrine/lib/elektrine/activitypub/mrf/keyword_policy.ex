defmodule Elektrine.ActivityPub.MRF.KeywordPolicy do
  @moduledoc """
  MRF policy for filtering content based on keywords and regex patterns.

  ## Configuration

  Configure in runtime.exs or config.exs:

      config :elektrine, :mrf_keyword,
        reject: [
          "spam phrase",
          ~r/buy.*now/i
        ],
        federated_timeline_removal: [
          "controversial topic",
          ~r/politics/i
        ],
        replace: [
          {~r/bad word/i, "****"}
        ],
        mark_sensitive: [
          ~r/nsfw/i,
          "adult content"
        ]

  ## Actions

  - `reject` - Block the activity entirely
  - `federated_timeline_removal` - Remove from federated timeline but allow to followers
  - `replace` - Replace matching text with specified replacement
  - `mark_sensitive` - Mark the post as sensitive/NSFW

  ## Pattern Types

  - String: Exact case-insensitive match
  - Regex: Full regex pattern matching
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  require Logger

  @impl true
  def filter(%{"type" => "Create", "object" => object} = activity) when is_map(object) do
    with {:ok, object} <- check_reject(object),
         {:ok, object} <- check_replace(object),
         {:ok, object} <- check_federated_timeline_removal(object),
         {:ok, object} <- check_mark_sensitive(object) do
      {:ok, Map.put(activity, "object", object)}
    end
  end

  # Also filter Update activities
  def filter(%{"type" => "Update", "object" => object} = activity) when is_map(object) do
    with {:ok, object} <- check_reject(object),
         {:ok, object} <- check_replace(object),
         {:ok, object} <- check_federated_timeline_removal(object),
         {:ok, object} <- check_mark_sensitive(object) do
      {:ok, Map.put(activity, "object", object)}
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    config = get_config()

    # Only expose counts in describe, not actual patterns (for security)
    {:ok,
     %{
       mrf_keyword: %{
         reject_count: length(config[:reject] || []),
         federated_timeline_removal_count: length(config[:federated_timeline_removal] || []),
         replace_count: length(config[:replace] || []),
         mark_sensitive_count: length(config[:mark_sensitive] || [])
       }
     }}
  end

  # Private functions

  defp check_reject(object) do
    patterns = get_config()[:reject] || []

    if matches_any?(object, patterns) do
      Logger.info("KeywordPolicy: Rejecting activity due to keyword match")
      {:reject, "Blocked by keyword filter"}
    else
      {:ok, object}
    end
  end

  defp check_replace(object) do
    replacements = get_config()[:replace] || []

    object =
      Enum.reduce(replacements, object, fn {pattern, replacement}, obj ->
        apply_replacement(obj, pattern, replacement)
      end)

    {:ok, object}
  end

  defp check_federated_timeline_removal(object) do
    patterns = get_config()[:federated_timeline_removal] || []

    if matches_any?(object, patterns) do
      # Remove from federated timeline by adjusting visibility
      # This is done by setting a flag that the timeline queries will check
      object =
        object
        |> Map.put("_mrf_federated_timeline_removal", true)

      {:ok, object}
    else
      {:ok, object}
    end
  end

  defp check_mark_sensitive(object) do
    patterns = get_config()[:mark_sensitive] || []

    if matches_any?(object, patterns) do
      object = Map.put(object, "sensitive", true)
      {:ok, object}
    else
      {:ok, object}
    end
  end

  defp matches_any?(object, patterns) do
    content = extract_searchable_content(object)
    Enum.any?(patterns, fn pattern -> matches_pattern?(content, pattern) end)
  end

  defp extract_searchable_content(object) do
    # Combine all searchable fields
    fields = [
      object["content"],
      object["summary"],
      object["name"],
      # Check hashtags
      extract_hashtags(object["tag"])
    ]

    fields
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> strip_html()
    |> String.downcase()
  end

  defp extract_hashtags(nil), do: ""

  defp extract_hashtags(tags) when is_list(tags) do
    tags
    |> Enum.filter(fn tag -> is_map(tag) && tag["type"] == "Hashtag" end)
    |> Enum.map_join(" ", fn tag -> tag["name"] || "" end)
  end

  defp extract_hashtags(_), do: ""

  defp strip_html(nil), do: ""

  defp strip_html(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp matches_pattern?(content, %Regex{} = regex) do
    Regex.match?(regex, content)
  end

  defp matches_pattern?(content, pattern) when is_binary(pattern) do
    String.contains?(content, String.downcase(pattern))
  end

  defp matches_pattern?(_, _), do: false

  defp apply_replacement(object, pattern, replacement) do
    content = object["content"]

    if content do
      new_content = replace_in_text(content, pattern, replacement)
      Map.put(object, "content", new_content)
    else
      object
    end
  end

  defp replace_in_text(text, %Regex{} = pattern, replacement) do
    Regex.replace(pattern, text, replacement)
  end

  defp replace_in_text(text, pattern, replacement) when is_binary(pattern) do
    # Case-insensitive string replacement
    regex = Regex.compile!(Regex.escape(pattern), "i")
    Regex.replace(regex, text, replacement)
  end

  defp get_config do
    Application.get_env(:elektrine, :mrf_keyword, [])
  end
end
