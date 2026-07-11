defmodule Elektrine.WebIndex.SchedulerWorker do
  @moduledoc "Seeds configured sites and schedules due independent-index crawls."

  use Oban.Worker, queue: :crawler, max_attempts: 1

  alias Elektrine.WebIndex

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    config = Application.get_env(:elektrine, :web_index, [])

    if Keyword.get(config, :enabled, false) do
      config
      |> Keyword.get(:seeds, [])
      |> Enum.each(fn url -> _result = WebIndex.seed(url, enqueue?: false) end)

      _count = WebIndex.enqueue_due(Keyword.get(config, :schedule_batch_size, 100))
    end

    :ok
  end
end
