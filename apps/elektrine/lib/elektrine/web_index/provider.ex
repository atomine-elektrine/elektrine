defmodule Elektrine.WebIndex.Provider do
  @moduledoc "Paige provider backed by Elektrine's independent PostgreSQL web index."

  alias Elektrine.WebIndex

  def search(query, opts \\ []) do
    results =
      query
      |> WebIndex.search(opts)
      |> Enum.map(fn result ->
        %{
          title: result.title,
          url: result.url,
          snippet: snippet(result),
          source: "Paige Index",
          score: result.score,
          published_at: result.fetched_at,
          metadata: %{kind: :web, language: result.language, independent_index: true}
        }
      end)

    {:ok, results}
  rescue
    _error -> {:error, :index_unavailable}
  end

  defp snippet(%{description: description}) when is_binary(description) and description != "",
    do: String.slice(description, 0, 320)

  defp snippet(%{content: content}) when is_binary(content), do: String.slice(content, 0, 320)
  defp snippet(_result), do: nil
end
