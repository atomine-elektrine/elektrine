defmodule Elektrine.Accounts.Endorsements do
  @moduledoc """
  User-owned endorsed account relationships.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.{AccountEndorsement, User}
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo

  def endorse_account(user_id, %User{id: user_id}), do: {:error, :self_endorse}

  def endorse_account(user_id, %User{} = account) when is_integer(user_id) do
    attrs = %{user_id: user_id, endorsed_user_id: account.id}

    case Repo.get_by(AccountEndorsement, attrs) do
      %AccountEndorsement{} = endorsement -> {:ok, endorsement}
      nil -> insert_endorsement(attrs)
    end
  end

  def endorse_account(user_id, %Actor{} = actor) when is_integer(user_id) do
    attrs = %{user_id: user_id, remote_actor_id: actor.id}

    case Repo.get_by(AccountEndorsement, attrs) do
      %AccountEndorsement{} = endorsement -> {:ok, endorsement}
      nil -> insert_endorsement(attrs)
    end
  end

  def endorse_account(_user_id, _account), do: {:error, :invalid_account}

  def unendorse_account(user_id, %User{} = account) when is_integer(user_id) do
    delete_endorsement(user_id, endorsed_user_id: account.id)
  end

  def unendorse_account(user_id, %Actor{} = actor) when is_integer(user_id) do
    delete_endorsement(user_id, remote_actor_id: actor.id)
  end

  def unendorse_account(_user_id, _account), do: {:error, :invalid_account}

  def account_endorsed?(user_id, %User{} = account) when is_integer(user_id) do
    endorsement_exists?(user_id, endorsed_user_id: account.id)
  end

  def account_endorsed?(user_id, %Actor{} = actor) when is_integer(user_id) do
    endorsement_exists?(user_id, remote_actor_id: actor.id)
  end

  def account_endorsed?(_user_id, _account), do: false

  def list_endorsed_accounts(user_id) when is_integer(user_id) do
    endorsements =
      AccountEndorsement
      |> where([endorsement], endorsement.user_id == ^user_id)
      |> order_by([endorsement], desc: endorsement.inserted_at, desc: endorsement.id)
      |> preload([:endorsed_user, :remote_actor])
      |> Repo.all()

    Enum.flat_map(endorsements, fn
      %AccountEndorsement{endorsed_user: %User{} = user} -> [user]
      %AccountEndorsement{remote_actor: %Actor{} = actor} -> [actor]
      _endorsement -> []
    end)
  end

  def list_endorsed_accounts(_user_id), do: []

  defp insert_endorsement(attrs) do
    %AccountEndorsement{}
    |> AccountEndorsement.changeset(attrs)
    |> Repo.insert()
  end

  defp delete_endorsement(user_id, clauses) do
    case get_endorsement(user_id, clauses) do
      %AccountEndorsement{} = endorsement -> Repo.delete(endorsement)
      nil -> {:ok, :not_endorsed}
    end
  end

  defp endorsement_exists?(user_id, clauses) do
    not is_nil(get_endorsement(user_id, clauses))
  end

  defp get_endorsement(user_id, clauses) do
    clauses
    |> Keyword.put(:user_id, user_id)
    |> then(&Repo.get_by(AccountEndorsement, &1))
  end
end
