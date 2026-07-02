defmodule Elektrine.ActivityPub.MRF.MentionPolicy do
  @moduledoc """
  Rejects Create activities that mention protected actor URIs.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  alias Elektrine.ActivityPub.MRF.Utils

  @impl true
  def filter(%{"type" => "Create"} = activity) do
    rejected_actors =
      :elektrine
      |> Application.get_env(:mrf_mention, [])
      |> Keyword.get(:actors, [])

    case Enum.find(Utils.mention_recipients(activity), &(&1 in rejected_actors)) do
      actor when is_binary(actor) -> {:reject, "[MentionPolicy] rejected mention of #{actor}"}
      _ -> {:ok, activity}
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    count =
      :elektrine
      |> Application.get_env(:mrf_mention, [])
      |> Keyword.get(:actors, [])
      |> length()

    {:ok, %{mrf_mention: %{actor_count: count}}}
  end
end
