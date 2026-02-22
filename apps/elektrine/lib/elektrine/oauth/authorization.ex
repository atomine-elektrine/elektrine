defmodule Elektrine.OAuth.Authorization do
  @moduledoc """
  OAuth authorization codes for the Mastodon API OAuth flow.

  Authorization codes are short-lived tokens that get exchanged for
  access tokens during the OAuth authorization code flow.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.Accounts.User
  alias Elektrine.OAuth.App
  alias Elektrine.OAuth.Authorization
  alias Elektrine.Repo

  @type t :: %__MODULE__{}

  # Authorization codes expire after 10 minutes
  @authorization_lifetime 600

  schema "oauth_authorizations" do
    field(:token, :string)
    field(:scopes, {:array, :string}, default: [])
    field(:valid_until, :utc_datetime)
    field(:used, :boolean, default: false)

    belongs_to(:user, User)
    belongs_to(:app, App, foreign_key: :app_id)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a new authorization for the given app and user.
  """
  @spec create_authorization(App.t(), User.t(), [String.t()] | nil) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()}
  def create_authorization(%App{} = app, %User{} = user, scopes \\ nil) do
    %{
      scopes: scopes || app.scopes,
      user_id: user.id,
      app_id: app.id
    }
    |> create_changeset()
    |> Repo.insert()
  end

  @doc """
  Creates a changeset for a new authorization.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs \\ %{}) do
    %Authorization{}
    |> cast(attrs, [:user_id, :app_id, :scopes, :valid_until])
    |> validate_required([:app_id, :scopes])
    |> add_token()
    |> add_lifetime()
  end

  @doc """
  Marks an authorization as used and returns it if valid.
  """
  @spec use_token(Authorization.t()) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  def use_token(%Authorization{used: false, valid_until: valid_until} = auth) do
    if DateTime.diff(DateTime.utc_now(), valid_until) < 0 do
      auth
      |> use_changeset(%{used: true})
      |> Repo.update()
    else
      {:error, "authorization code expired"}
    end
  end

  def use_token(%Authorization{used: true}), do: {:error, "authorization code already used"}

  @doc """
  Gets an authorization by token for a specific app.
  """
  @spec get_by_token(App.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_by_token(%App{id: app_id}, token) do
    query = from(a in __MODULE__, where: a.app_id == ^app_id and a.token == ^token)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      auth -> {:ok, auth}
    end
  end

  @doc """
  Gets a pre-existing unused authorization for an app and user.
  """
  @spec get_existing(App.t(), User.t()) :: {:ok, t()} | {:error, :not_found}
  def get_existing(%App{id: app_id}, %User{id: user_id}) do
    query =
      from(a in __MODULE__,
        where: a.app_id == ^app_id and a.user_id == ^user_id and a.used == false,
        where: a.valid_until > ^DateTime.utc_now(),
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      auth -> {:ok, auth}
    end
  end

  @doc """
  Deletes all authorizations for a user.
  """
  @spec delete_user_authorizations(User.t()) :: {integer(), any()}
  def delete_user_authorizations(%User{id: user_id}) do
    from(a in __MODULE__, where: a.user_id == ^user_id)
    |> Repo.delete_all()
  end

  # Private functions

  defp use_changeset(%Authorization{} = auth, params) do
    auth
    |> cast(params, [:used])
    |> validate_required([:used])
  end

  defp add_token(changeset) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    put_change(changeset, :token, token)
  end

  defp add_lifetime(changeset) do
    valid_until = DateTime.add(DateTime.utc_now(), @authorization_lifetime, :second)
    put_change(changeset, :valid_until, valid_until)
  end
end
