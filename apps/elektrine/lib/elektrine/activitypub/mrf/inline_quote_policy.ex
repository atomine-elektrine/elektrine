defmodule Elektrine.ActivityPub.MRF.InlineQuotePolicy do
  @moduledoc """
  Appends a visible quote URL line to quoted posts for clients that ignore quote metadata.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  @impl true
  def filter(%{"object" => %{"quoteUrl" => quote_url} = object} = activity)
      when is_binary(quote_url) do
    {:ok, Map.put(activity, "object", inline_quote(object, quote_url))}
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    {:ok, %{mrf_inline_quote: %{template: template()}}}
  end

  defp inline_quote(%{"content" => content} = object, quote_url) when is_binary(content) do
    if inline_quote_present?(content, quote_url) do
      object
    else
      Map.put(object, "content", append_quote(content, quote_url))
    end
  end

  defp inline_quote(object, quote_url),
    do: Map.put(object, "content", append_quote("", quote_url))

  defp append_quote(content, quote_url) do
    quote_line =
      template()
      |> String.replace("{url}", ~s(<a href="#{quote_url}">#{quote_url}</a>))
      |> then(&~s(<span class="quote-inline"><br><br>#{&1}</span>))

    if String.ends_with?(content, "</p>") do
      String.replace_suffix(content, "</p>", quote_line <> "</p>")
    else
      content <> quote_line
    end
  end

  defp inline_quote_present?(content, quote_url) do
    String.contains?(content, quote_url) or
      String.contains?(content, ~s(class="quote-inline")) or
      String.contains?(content, ~s(class='quote-inline'))
  end

  defp template do
    :elektrine
    |> Application.get_env(:mrf_inline_quote, [])
    |> Keyword.get(:template, "QT: {url}")
  end
end
