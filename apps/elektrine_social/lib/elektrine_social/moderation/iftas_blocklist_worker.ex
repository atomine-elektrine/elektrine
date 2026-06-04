defmodule ElektrineSocial.Moderation.IftasBlocklistWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :federation,
    max_attempts: 3,
    unique: [period: :timer.hours(6), states: [:available, :scheduled, :executing]]

  alias ElektrineSocial.Moderation.IftasBlocklist

  def enqueue(opts \\ []) do
    opts
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    opts =
      args
      |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)
      |> Keyword.new()

    case IftasBlocklist.sync(opts) do
      {:ok, _result} -> :ok
      {:error, :empty_blocklist} -> {:discard, :empty_blocklist}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:error, :invalid_args}
  end
end
