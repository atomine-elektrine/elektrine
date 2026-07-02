defmodule Elektrine.ActivityPub.MRF.NoEmptyPolicy do
  @moduledoc """
  Rejects local Note creates/updates that contain no real content.

  This catches accidental posts that are blank or only mention handles, while
  allowing media-only posts with attachments.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  alias Elektrine.ActivityPub.MRF.Utils

  @impl true
  def filter(%{"actor" => actor, "object" => %{"type" => "Note"} = object} = activity)
      when is_binary(actor) do
    if Utils.local_actor?(actor) and Utils.create_or_update?(activity) and empty_note?(object) do
      {:reject, "[NoEmptyPolicy] empty local note"}
    else
      {:ok, activity}
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe, do: {:ok, %{mrf_no_empty: true}}

  defp empty_note?(object) do
    not has_attachment?(object) and only_mentions_or_blank?(source_text(object))
  end

  defp has_attachment?(%{"attachment" => attachments}) when is_list(attachments),
    do: attachments != []

  defp has_attachment?(_), do: false

  defp source_text(%{"source" => %{"content" => content}}), do: content
  defp source_text(%{"source" => source}) when is_binary(source), do: source
  defp source_text(%{"content" => content}) when is_binary(content), do: Utils.strip_html(content)
  defp source_text(_), do: ""

  defp only_mentions_or_blank?(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&String.starts_with?(&1, "@"))
    |> Enum.empty?()
  end
end
