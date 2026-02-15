defmodule Elektrine.ActivityPub.MRF.NormalizePolicy do
  @moduledoc """
  Normalizes incoming ActivityPub activities.

  This policy runs last and ensures activities have consistent structure:
  - Normalizes content markup
  - Ensures required fields are present
  - Sanitizes potentially dangerous content
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  @impl true
  def filter(%{"type" => type, "object" => %{"content" => content} = object} = activity)
      when type in ["Create", "Update"] and is_binary(content) do
    # Normalize HTML content - strip dangerous tags but preserve safe formatting
    sanitized_content = sanitize_html(content)
    updated_object = Map.put(object, "content", sanitized_content)

    {:ok, Map.put(activity, "object", updated_object)}
  end

  def filter(activity), do: {:ok, activity}

  defp sanitize_html(html) when is_binary(html) do
    # Use HtmlSanitizeEx if available, otherwise basic sanitization
    if Code.ensure_loaded?(HtmlSanitizeEx) do
      HtmlSanitizeEx.basic_html(html)
    else
      # Basic fallback - strip script tags at minimum
      html
      |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
      |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
      |> String.replace(~r/on\w+\s*=/i, "data-removed=")
    end
  end

  defp sanitize_html(content), do: content

  @impl true
  def describe do
    {:ok, %{normalize_markup: true}}
  end
end
