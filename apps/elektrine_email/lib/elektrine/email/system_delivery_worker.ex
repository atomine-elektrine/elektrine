defmodule Elektrine.Email.SystemDeliveryWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :email,
    max_attempts: 1

  require Logger

  alias Elektrine.Email.SystemDelivery

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case SystemDelivery.deliver_email_to_all_users(args) do
      {:ok, summary} ->
        Logger.info("System email delivered: #{inspect(summary)}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
