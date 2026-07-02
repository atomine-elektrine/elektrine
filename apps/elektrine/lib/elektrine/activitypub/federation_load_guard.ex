defmodule Elektrine.ActivityPub.FederationLoadGuard do
  @moduledoc """
  Back-pressure guard for nonessential federation jobs.
  """

  import Ecto.Query

  alias Elektrine.Repo
  alias Oban.Job

  @default_threshold 50_000

  def overloaded? do
    enabled?() and queued_federation_jobs() >= threshold()
  end

  def skip_nonessential?(component \\ :unknown) do
    skip? = overloaded?()

    if skip? do
      :telemetry.execute(
        [:elektrine, :federation, :load_guard, :skip],
        %{count: 1},
        %{component: component}
      )
    end

    skip?
  end

  def allow_nonessential? do
    not skip_nonessential?()
  end

  def queued_federation_jobs do
    count =
      Repo.one(
        from j in Job,
          where: j.queue == "federation" and j.state in ["available", "retryable"],
          select: count(j.id)
      ) || 0

    :telemetry.execute(
      [:elektrine, :federation, :queue_depth],
      %{jobs: count},
      %{queue: :federation, states: "available,retryable"}
    )

    count
  end

  defp enabled? do
    :elektrine
    |> Application.get_env(:federation_load_guard, [])
    |> Keyword.get(:enabled, true)
  end

  defp threshold do
    :elektrine
    |> Application.get_env(:federation_load_guard, [])
    |> Keyword.get(:max_available_or_retryable, @default_threshold)
  end
end
