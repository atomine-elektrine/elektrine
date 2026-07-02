defmodule Elektrine.ActivityPub.MRF.RejectNonPublicPolicy do
  @moduledoc """
  Rejects incoming non-public Create activities unless explicitly allowed.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  alias Elektrine.ActivityPub.MRF.Utils

  @impl true
  def filter(%{"type" => "Create"} = activity) do
    config = Application.get_env(:elektrine, :mrf_reject_non_public, [])

    case Utils.visibility(activity) do
      visibility when visibility in ["public", "unlisted"] ->
        {:ok, activity}

      "followers" ->
        if Keyword.get(config, :allow_followers_only, false) do
          {:ok, activity}
        else
          {:reject, "[RejectNonPublicPolicy] followers-only activity rejected"}
        end

      "direct" ->
        if Keyword.get(config, :allow_direct, false) do
          {:ok, activity}
        else
          {:reject, "[RejectNonPublicPolicy] direct activity rejected"}
        end
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    {:ok,
     %{
       mrf_reject_non_public:
         Application.get_env(:elektrine, :mrf_reject_non_public, []) |> Map.new()
     }}
  end
end
