defmodule Atomine.Credits do
  @moduledoc """
  Atomine Credits are scarce balances used for anti-abuse gates.

  Credits are granted by trusted signals and spent by risky actions. This module
  is intentionally ledger-backed so abuse review can trace where capacity came
  from and where it was consumed.
  """

  import Ecto.Query, warn: false

  alias Atomine.{CreditAccount, CreditLedgerEntry, CreditSpend}
  alias Elektrine.Repo

  @type credit_type :: String.t() | atom()

  @doc "Returns supported credit type identifiers."
  def credit_types, do: CreditAccount.credit_types()

  @doc "Returns the current balance for a user and credit type."
  def balance(user_id, credit_type) do
    case normalize_credit_type(credit_type) do
      {:ok, credit_type} ->
        CreditAccount
        |> where([a], a.user_id == ^user_id and a.credit_type == ^credit_type)
        |> select([a], a.balance)
        |> Repo.one()
        |> Kernel.||(0)

      {:error, _reason} ->
        0
    end
  end

  @doc "Grants credits and records a positive ledger entry."
  def grant(user_id, credit_type, amount, reason, opts \\ [])

  def grant(user_id, credit_type, amount, reason, opts)
      when is_integer(user_id) and is_integer(amount) and amount > 0 and is_binary(reason) do
    with {:ok, credit_type} <- normalize_credit_type(credit_type) do
      Repo.transaction(fn ->
        account = get_or_insert_account!(user_id, credit_type)

        account
        |> CreditAccount.changeset(%{
          balance: account.balance + amount,
          lifetime_earned: account.lifetime_earned + amount
        })
        |> Repo.update!()

        %CreditLedgerEntry{}
        |> CreditLedgerEntry.changeset(%{
          user_id: user_id,
          credit_type: credit_type,
          amount: amount,
          reason: reason,
          action: Keyword.get(opts, :action),
          reference_type: Keyword.get(opts, :reference_type),
          reference_id: reference_id(opts),
          metadata: Keyword.get(opts, :metadata, %{})
        })
        |> Repo.insert!()
      end)
    end
  end

  def grant(_user_id, credit_type, _amount, _reason, _opts) do
    with {:ok, _credit_type} <- normalize_credit_type(credit_type), do: {:error, :invalid_grant}
  end

  @doc "Grants credits once for a stable reference."
  def grant_once(user_id, credit_type, amount, reason, opts \\ [])

  def grant_once(user_id, credit_type, amount, reason, opts) do
    with {:ok, credit_type} <- normalize_credit_type(credit_type) do
      case existing_grant(user_id, credit_type, reason, opts) do
        %CreditLedgerEntry{} = ledger_entry ->
          {:ok, ledger_entry}

        nil ->
          grant(user_id, credit_type, amount, reason, opts)
      end
    end
  end

  @doc "Spends credits once for an action and audience."
  def spend(user_id, credit_type, amount, action, audience, opts \\ [])

  def spend(user_id, credit_type, amount, action, audience, opts)
      when is_integer(user_id) and is_integer(amount) and amount > 0 and is_binary(action) and
             is_binary(audience) do
    with {:ok, credit_type} <- normalize_credit_type(credit_type) do
      Repo.transaction(fn ->
        idempotency_key = Keyword.get(opts, :idempotency_key)

        case existing_spend(user_id, credit_type, action, idempotency_key) do
          %CreditSpend{} = spend ->
            spend

          nil ->
            spend_fresh!(user_id, credit_type, amount, action, audience, opts)
        end
      end)
    end
  end

  def spend(_user_id, credit_type, _amount, _action, _audience, _opts) do
    with {:ok, _credit_type} <- normalize_credit_type(credit_type), do: {:error, :invalid_spend}
  end

  @doc "Returns recent ledger entries for a user."
  def list_ledger_entries(user_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> min(200)

    CreditLedgerEntry
    |> where([e], e.user_id == ^user_id)
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Returns credit accounts for a user ordered by credit type."
  def list_accounts(user_id) do
    CreditAccount
    |> where([a], a.user_id == ^user_id)
    |> order_by([a], asc: a.credit_type)
    |> Repo.all()
  end

  defp spend_fresh!(user_id, credit_type, amount, action, audience, opts) do
    account = lock_account(user_id, credit_type)

    if is_nil(account) or account.balance < amount do
      Repo.rollback(:insufficient_credits)
    end

    account
    |> CreditAccount.changeset(%{
      balance: account.balance - amount,
      lifetime_spent: account.lifetime_spent + amount
    })
    |> Repo.update!()

    spend =
      %CreditSpend{}
      |> CreditSpend.changeset(%{
        user_id: user_id,
        credit_type: credit_type,
        amount: amount,
        action: action,
        audience: audience,
        idempotency_key: Keyword.get(opts, :idempotency_key),
        metadata: Keyword.get(opts, :metadata, %{})
      })
      |> Repo.insert!()

    %CreditLedgerEntry{}
    |> CreditLedgerEntry.changeset(%{
      user_id: user_id,
      credit_type: credit_type,
      amount: -amount,
      reason: "spend:#{action}",
      action: action,
      reference_type: "atomine_credit_spend",
      reference_id: to_string(spend.id),
      metadata: %{"audience" => audience}
    })
    |> Repo.insert!()

    spend
  end

  defp existing_spend(_user_id, _credit_type, _action, nil), do: nil
  defp existing_spend(_user_id, _credit_type, _action, ""), do: nil

  defp existing_spend(user_id, credit_type, action, idempotency_key) do
    Repo.get_by(CreditSpend,
      user_id: user_id,
      credit_type: credit_type,
      action: action,
      idempotency_key: idempotency_key
    )
  end

  defp existing_grant(user_id, credit_type, reason, opts) do
    reference_type = Keyword.get(opts, :reference_type)
    reference_id = reference_id(opts)

    if is_nil(reference_type) or is_nil(reference_id) do
      nil
    else
      Repo.get_by(CreditLedgerEntry,
        user_id: user_id,
        credit_type: credit_type,
        reason: reason,
        reference_type: reference_type,
        reference_id: reference_id
      )
    end
  end

  defp get_or_insert_account!(user_id, credit_type) do
    case lock_account(user_id, credit_type) do
      %CreditAccount{} = account ->
        account

      nil ->
        %CreditAccount{}
        |> CreditAccount.changeset(%{user_id: user_id, credit_type: credit_type})
        |> Repo.insert!(on_conflict: :nothing, conflict_target: [:user_id, :credit_type])

        lock_account(user_id, credit_type)
    end
  end

  defp lock_account(user_id, credit_type) do
    CreditAccount
    |> where([a], a.user_id == ^user_id and a.credit_type == ^credit_type)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp normalize_credit_type(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_credit_type()

  defp normalize_credit_type(value) when is_binary(value) do
    credit_type = String.trim(value)

    if credit_type in CreditAccount.credit_types() do
      {:ok, credit_type}
    else
      {:error, :invalid_credit_type}
    end
  end

  defp normalize_credit_type(_value), do: {:error, :invalid_credit_type}

  defp reference_id(opts) do
    case Keyword.get(opts, :reference_id) do
      nil -> nil
      value -> to_string(value)
    end
  end
end
