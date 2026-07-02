defmodule Elektrine.ActivityPub.MRF.QuoteToLinkTagPolicy do
  @moduledoc """
  Ensures quoted posts also carry an ActivityPub Link tag for compatibility.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  @activity_json "application/activity+json"

  @impl true
  def filter(%{"object" => %{"quoteUrl" => quote_url} = object} = activity)
      when is_binary(quote_url) do
    {:ok, Map.put(activity, "object", ensure_quote_link_tag(object, quote_url))}
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe, do: {:ok, %{mrf_quote_to_link_tag: true}}

  defp ensure_quote_link_tag(object, quote_url) do
    tags = object |> Map.get("tag", []) |> List.wrap()

    if Enum.any?(tags, &quote_link_tag?(&1, quote_url)) do
      object
    else
      Map.put(
        object,
        "tag",
        tags ++ [%{"type" => "Link", "mediaType" => @activity_json, "href" => quote_url}]
      )
    end
  end

  defp quote_link_tag?(%{"type" => "Link", "href" => href}, quote_url), do: href == quote_url
  defp quote_link_tag?(_tag, _quote_url), do: false
end
