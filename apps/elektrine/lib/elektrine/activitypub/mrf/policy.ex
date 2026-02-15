defmodule Elektrine.ActivityPub.MRF.Policy do
  @moduledoc """
  Behaviour for MRF (Message Rewrite Facility) policies.

  MRF policies can filter, modify, or reject incoming ActivityPub activities.
  They are applied in order before any activity processing occurs.

  ## Implementing a Policy

      defmodule MyApp.MRF.MyPolicy do
        @behaviour Elektrine.ActivityPub.MRF.Policy

        @impl true
        def filter(activity) do
          # Return {:ok, activity} to pass through
          # Return {:ok, modified_activity} to modify
          # Return {:reject, reason} to reject
          {:ok, activity}
        end

        @impl true
        def describe do
          {:ok, %{}}
        end
      end
  """

  @doc """
  Filters an incoming activity.

  Returns:
  - `{:ok, activity}` - Activity passes through unchanged
  - `{:ok, modified_activity}` - Activity is modified before processing
  - `{:reject, reason}` - Activity is rejected with the given reason
  """
  @callback filter(activity :: map()) :: {:ok, map()} | {:reject, String.t()}

  @doc """
  Describes the policy's current configuration.
  Used for transparency reporting in nodeinfo.
  """
  @callback describe() :: {:ok, map()} | {:error, any()}

  @doc """
  Optional: Returns configuration description for admin UI.
  """
  @callback config_description() :: map()

  @optional_callbacks config_description: 0
end
