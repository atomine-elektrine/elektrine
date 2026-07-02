defmodule Elektrine.ActivityPub.MRF.NoPlaceholderTextPolicy do
  @moduledoc """
  Removes placeholder content from media posts.

  Some servers send media-only posts with "." or "<p>.</p>" as filler text.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  @impl true
  def filter(
        %{"type" => type, "object" => %{"content" => content, "attachment" => attachments}} =
          activity
      )
      when type in ["Create", "Update"] and content in [".", "<p>.</p>"] and is_list(attachments) and
             attachments != [] do
    {:ok, put_in(activity, ["object", "content"], "")}
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe, do: {:ok, %{mrf_no_placeholder_text: true}}
end
