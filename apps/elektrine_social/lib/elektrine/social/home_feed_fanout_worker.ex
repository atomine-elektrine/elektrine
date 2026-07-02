defmodule Elektrine.Social.HomeFeedFanoutWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 300,
      keys: [:message_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Elektrine.Social.HomeFeed

  def enqueue(message_id, opts \\ []) when is_integer(message_id) do
    args = %{"message_id" => message_id, "opts" => Map.new(opts)}

    if inline_testing?() do
      _ = perform(%Oban.Job{args: args})
      {:ok, %Oban.Job{args: args}}
    else
      args
      |> new()
      |> Oban.insert()
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id, "opts" => opts}})
      when is_integer(message_id) do
    HomeFeed.fanout_message(message_id, keyword_opts(opts))
  end

  def perform(%Oban.Job{args: %{"message_id" => message_id}}) when is_integer(message_id) do
    HomeFeed.fanout_message(message_id)
  end

  defp keyword_opts(opts) when is_map(opts) do
    Enum.map(opts, fn {key, value} -> {String.to_existing_atom(key), value} end)
  rescue
    ArgumentError -> []
  end

  defp keyword_opts(_opts), do: []

  defp inline_testing? do
    :elektrine
    |> Application.get_env(Oban, [])
    |> Keyword.get(:testing) == :inline
  end
end
