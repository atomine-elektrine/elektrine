defmodule Elektrine.Profiles.PublicSiteAnalyticsRollupWorker do
  @moduledoc """
  Refreshes public site analytics rollups used by domain analytics pages.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, priority: 8

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    days =
      args
      |> Map.get("days", 2)
      |> parse_positive_int(2)

    counts = Elektrine.Profiles.refresh_public_site_analytics_rollups(days: days)
    Logger.info("Refreshed public site analytics rollups for #{days} days: #{inspect(counts)}")

    :ok
  end

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_value, default), do: default
end
