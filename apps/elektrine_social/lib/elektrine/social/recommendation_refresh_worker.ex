defmodule Elektrine.Social.RecommendationRefreshWorker do
  @moduledoc """
  Refreshes persisted recommendation rows outside the page request path.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 120,
      keys: [:user_id, :filter],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Elektrine.Social.Recommendations

  @default_limit 100

  def enqueue(user_id, opts \\ []) when is_integer(user_id) do
    filter = opts |> Keyword.get(:filter, "all") |> normalize_filter()
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()

    args = %{"user_id" => user_id, "filter" => filter, "limit" => limit}

    if skip_enqueue_for_inline_test?() do
      {:ok, %Oban.Job{args: args, worker: inspect(__MODULE__)}}
    else
      args
      |> new()
      |> Oban.insert()
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "filter" => filter, "limit" => limit}})
      when is_integer(user_id) and is_binary(filter) and is_integer(limit) do
    Recommendations.refresh_stored_feed(user_id, filter, limit)
    :ok
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_args}

  defp normalize_filter(filter) when filter in ~w(all timeline gallery discussions), do: filter
  defp normalize_filter(_filter), do: "all"

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(20) |> min(200)
  defp normalize_limit(_limit), do: @default_limit

  defp skip_enqueue_for_inline_test? do
    Process.get(:oban_testing) != :manual and
      inline_testing?()
  end

  defp inline_testing? do
    :elektrine
    |> Application.get_env(Oban, [])
    |> Keyword.get(:testing) == :inline
  end
end
