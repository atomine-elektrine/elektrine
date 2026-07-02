defmodule Elektrine.Accounts.MuteExpireWorker do
  @moduledoc """
  Removes temporary user mutes when their expiration time arrives.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 3600, fields: [:args], keys: [:muter_id, :muted_id]]

  alias Elektrine.Accounts
  alias Elektrine.Accounts.UserMute
  alias Elektrine.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"muter_id" => muter_id, "muted_id" => muted_id}}) do
    case Repo.get_by(UserMute, muter_id: muter_id, muted_id: muted_id) do
      %UserMute{expires_at: %DateTime{} = expires_at} ->
        if DateTime.compare(expires_at, Elektrine.Time.utc_now()) in [:lt, :eq] do
          _ = Accounts.unmute_user(muter_id, muted_id)
          :ok
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  def enqueue(%{muter_id: muter_id, muted_id: muted_id}, %DateTime{} = scheduled_at) do
    %{"muter_id" => muter_id, "muted_id" => muted_id}
    |> new(scheduled_at: scheduled_at)
    |> Elektrine.JobQueue.insert()
  end
end
