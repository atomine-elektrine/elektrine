defmodule ElektrineSocial.Moderation.IftasBlocklistWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :federation,
    max_attempts: 3,
    unique: [period: :timer.hours(6), states: [:available, :scheduled, :executing]]

  alias ElektrineSocial.Moderation.IftasBlocklist

  @opt_keys %{
    "enabled" => :enabled,
    "url" => :url,
    "remove_stale?" => :remove_stale?,
    "max_body_bytes" => :max_body_bytes
  }

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
      |> Enum.flat_map(fn
        {key, value} when is_binary(key) ->
          case Map.fetch(@opt_keys, key) do
            {:ok, opt_key} -> [{opt_key, value}]
            :error -> []
          end

        {key, value} when is_atom(key) ->
          [{key, value}]

        _ ->
          []
      end)
      |> Keyword.new()

    case IftasBlocklist.sync(opts) do
      {:ok, _result} -> :ok
      {:error, :empty_blocklist} -> {:discard, :empty_blocklist}
      {:error, reason} -> {:error, reason}
    end
  end
end
