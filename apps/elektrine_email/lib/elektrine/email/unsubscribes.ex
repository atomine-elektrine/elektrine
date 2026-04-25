defmodule Elektrine.Email.Unsubscribes do
  @moduledoc """
  Context for managing email unsubscriptions (RFC 8058).
  """

  import Ecto.Query
  alias Elektrine.Email.Unsubscribe
  alias Elektrine.Repo

  @token_salt "email unsubscribe"
  @token_max_age 366 * 24 * 60 * 60

  @doc """
  Generates a unique unsubscribe token for an email address and optional list.
  """
  def generate_token(email, list_id \\ nil) do
    Phoenix.Token.sign(ElektrineWeb.Endpoint, @token_salt, %{
      "email" => normalize_email(email),
      "list_id" => list_id
    })
  end

  @doc """
  Records an unsubscribe request.

  ## Parameters
  - `email` - The email address to unsubscribe
  - `opts` - Keyword list with optional fields:
    - `:list_id` - Specific list to unsubscribe from (default: nil for all)
    - `:user_id` - Associated user ID if known
    - `:ip_address` - IP address of the requester
    - `:user_agent` - User agent string
    - `:token` - Unsubscribe token (generated if not provided)
  """
  def unsubscribe(email, opts \\ []) do
    email = normalize_email(email)
    list_id = Keyword.get(opts, :list_id)
    token = Keyword.get(opts, :token) || generate_token(email, list_id)

    attrs = %{
      email: email,
      list_id: list_id,
      user_id: Keyword.get(opts, :user_id),
      token: token,
      unsubscribed_at: DateTime.utc_now(),
      ip_address: Keyword.get(opts, :ip_address),
      user_agent: Keyword.get(opts, :user_agent)
    }

    case get_existing_unsubscribe(email, list_id) do
      %Unsubscribe{} = unsubscribe ->
        unsubscribe
        |> Unsubscribe.changeset(attrs)
        |> Repo.update()

      nil ->
        %Unsubscribe{}
        |> Unsubscribe.changeset(attrs)
        |> Repo.insert(
          on_conflict: {:replace, [:unsubscribed_at, :ip_address, :user_agent, :updated_at]},
          conflict_target: [:email, :list_id]
        )
    end
  end

  @doc """
  Checks if an email address has unsubscribed from a specific list or globally.

  Returns `true` if unsubscribed, `false` otherwise.
  """
  def unsubscribed?(email, list_id \\ nil) do
    email = normalize_email(email)

    query =
      from u in Unsubscribe,
        where: u.email == ^email,
        where: is_nil(u.list_id) or u.list_id == ^list_id

    Repo.exists?(query)
  end

  @doc """
  Resubscribes an email address to a specific list or globally.
  """
  def resubscribe(email, list_id \\ nil) do
    email = normalize_email(email)

    query =
      from u in Unsubscribe,
        where: u.email == ^email

    query =
      if list_id do
        where(query, [u], u.list_id == ^list_id)
      else
        where(query, [u], is_nil(u.list_id))
      end

    {count, _} = Repo.delete_all(query)
    {:ok, count}
  end

  @doc """
  Gets all unsubscribe records for an email address.
  """
  def list_unsubscribes(email) do
    email = normalize_email(email)

    from(u in Unsubscribe,
      where: u.email == ^email,
      order_by: [desc: u.unsubscribed_at]
    )
    |> Repo.all()
  end

  @doc """
  Verifies an unsubscribe token and returns the associated email and list_id.
  """
  def verify_token(token) do
    case Phoenix.Token.verify(ElektrineWeb.Endpoint, @token_salt, token, max_age: @token_max_age) do
      {:ok, %{"email" => email, "list_id" => list_id}} when is_binary(email) ->
        {:ok, %{email: normalize_email(email), list_id: list_id, token: token}}

      {:ok, %{email: email, list_id: list_id}} when is_binary(email) ->
        {:ok, %{email: normalize_email(email), list_id: list_id, token: token}}

      _ ->
        verify_legacy_token(token)
    end
  end

  defp verify_legacy_token(token) do
    case Repo.get_by(Unsubscribe, token: token) do
      %Unsubscribe{} = unsubscribe ->
        {:ok, %{email: unsubscribe.email, list_id: unsubscribe.list_id, token: token}}

      nil ->
        {:error, :invalid_token}
    end
  end

  defp get_existing_unsubscribe(email, nil) do
    from(u in Unsubscribe, where: u.email == ^email and is_nil(u.list_id), limit: 1)
    |> Repo.one()
  end

  defp get_existing_unsubscribe(email, list_id) do
    Repo.get_by(Unsubscribe, email: email, list_id: list_id)
  end

  @doc """
  Batch checks unsubscribe status for multiple emails and list IDs.

  Returns a map of %{email => %{list_id => unsubscribed?}}

  This is more efficient than calling `unsubscribed?/2` in a loop as it performs
  a single database query instead of N queries.
  """
  def batch_check_unsubscribed(emails, list_ids) do
    emails = Enum.map(emails, &normalize_email/1)

    # Get all unsubscribe records for these emails in a single query
    unsubscribes =
      from(u in Unsubscribe,
        where: u.email in ^emails,
        where: is_nil(u.list_id) or u.list_id in ^list_ids,
        select: {u.email, u.list_id}
      )
      |> Repo.all()

    # Build a set for quick lookup
    # If list_id is nil, that means the user is globally unsubscribed
    global_unsubscribes = MapSet.new(for {email, nil} <- unsubscribes, do: email)

    specific_unsubscribes =
      MapSet.new(
        for {email, list_id} when not is_nil(list_id) <- unsubscribes, do: {email, list_id}
      )

    # Build the result map
    for email <- emails, into: %{} do
      is_globally_unsubscribed = MapSet.member?(global_unsubscribes, email)

      status =
        for list_id <- list_ids, into: %{} do
          is_unsubscribed =
            is_globally_unsubscribed or
              MapSet.member?(specific_unsubscribes, {email, list_id})

          {list_id, is_unsubscribed}
        end

      {email, status}
    end
  end

  @doc """
  Gets unsubscribe statistics.
  """
  def stats do
    total = Repo.aggregate(Unsubscribe, :count)

    recent =
      from(u in Unsubscribe,
        where: u.unsubscribed_at > ago(7, "day")
      )
      |> Repo.aggregate(:count)

    %{
      total: total,
      last_7_days: recent
    }
  end

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()
end
