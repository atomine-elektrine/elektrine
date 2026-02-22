defmodule Elektrine.Bluesky.InboundPollWorker do
  @moduledoc """
  Periodic worker that syncs inbound Bluesky interactions for enabled users.
  """

  use Oban.Worker,
    queue: :federation,
    max_attempts: 1,
    unique: [period: 90, states: [:available, :scheduled, :executing]]

  alias Elektrine.Bluesky.Inbound

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Inbound.sync_enabled_users() do
      {:ok, _summary} -> :ok
      {:skipped, _reason} -> :ok
    end
  end
end
