defmodule Elektrine.CustomDomains.AcmeChallengeStore do
  @moduledoc """
  Stores ACME HTTP-01 challenge tokens and responses.

  Challenges are stored in ETS for quick access during provisioning.

  Challenges are short-lived (typically validated within minutes).
  """

  use GenServer

  @table_name :acme_challenges
  # Challenges expire after 10 minutes
  @ttl_ms :timer.minutes(10)

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores a challenge token and response.
  """
  def put(token, response) do
    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table_name, {token, response, expires_at})
    :ok
  end

  @doc """
  Gets the response for a challenge token.
  """
  def get(token) do
    case get_from_ets(token) do
      {:ok, response} ->
        response

      :not_found ->
        nil
    end
  end

  @doc """
  Removes a challenge token.
  """
  def delete(token) do
    :ets.delete(@table_name, token)
    :ok
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :public, read_concurrency: true])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  ## Private Functions

  defp get_from_ets(token) do
    case :ets.lookup(@table_name, token) do
      [{^token, response, expires_at}] ->
        now = System.monotonic_time(:millisecond)

        if now < expires_at do
          {:ok, response}
        else
          :ets.delete(@table_name, token)
          :not_found
        end

      [] ->
        :not_found
    end
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn {token, _response, expires_at}, acc ->
        if now >= expires_at do
          :ets.delete(@table_name, token)
        end

        acc
      end,
      :ok,
      @table_name
    )
  end

  defp schedule_cleanup do
    # Cleanup every minute
    Process.send_after(self(), :cleanup, :timer.minutes(1))
  end
end
