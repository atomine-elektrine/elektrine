defmodule Elektrine.ActivityPub.MRF.QuietReplyPolicy do
  @moduledoc """
  Converts local public replies to unlisted replies.

  Replies are still delivered to expected recipients, but do not enter the
  federated public timeline by default.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  alias Elektrine.ActivityPub.MRF.Utils

  @impl true
  def filter(
        %{
          "type" => "Create",
          "actor" => actor,
          "to" => to,
          "object" => %{"type" => "Note", "inReplyTo" => in_reply_to}
        } = activity
      )
      when is_binary(actor) and is_binary(in_reply_to) and is_list(to) do
    if Utils.local_actor?(actor) and Utils.public_uri() in to do
      {:ok, Utils.quiet_reply(activity)}
    else
      {:ok, activity}
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe, do: {:ok, %{mrf_quiet_reply: true}}
end
