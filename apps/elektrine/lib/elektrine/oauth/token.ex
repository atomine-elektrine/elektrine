defmodule Elektrine.OAuth.Token do
  @moduledoc """
  OAuth access tokens for the Mastodon API.

  Access tokens are long-lived tokens that authenticate API requests.
  They can be obtained through the OAuth authorization code flow.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.Repo
  alias Elektrine.Accounts.User
  alias Elektrine.OAuth.App
  alias Elektrine.OAuth.Authorization
  alias Elektrine.OAuth.Token

  @type t :: %__MODULE__{}

  # Default token lifetime: 30 days
  @default_token_lifetime 30 * 24 * 60 * 60

  schema "oauth_tokens" do
    field(:token, :string)
    field(:refresh_token, :string)
    field(:scopes, {:array, :string}, default: [])
    field(:valid_until, :utc_datetime)

    belongs_to(:user, User)
    belongs_to(:app, App, foreign_key: :app_id)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Gets the configured token lifetime in seconds.
  """
  @spec lifespan() :: integer()
  def lifespan do
    Application.get_env(:elektrine, :oauth_token_lifetime, @default_token_lifetime)
  end

  @doc """
  Gets a token by its access token string.
  """
  @spec get_by_token(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_by_token(token) do
    query = from(t in __MODULE__, where: t.token == ^token, preload: [:user, :app])

    case Repo.one(query) do
      nil -> {:error, :not_found}
      token -> {:ok, token}
    end
  end

  @doc """
  Gets a token for an app by access token.
  """
  @spec get_by_token(App.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_by_token(%App{id: app_id}, token) do
    query =
      from(t in __MODULE__,
        where: t.app_id == ^app_id and t.token == ^token,
        preload: [:user, :app]
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      token -> {:ok, token}
    end
  end

  @doc """
  Gets a token for an app by refresh token.
  """
  @spec get_by_refresh_token(App.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_by_refresh_token(%App{id: app_id}, refresh_token) do
    query =
      from(t in __MODULE__,
        where: t.app_id == ^app_id and t.refresh_token == ^refresh_token,
        preload: [:user, :app]
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      token -> {:ok, token}
    end
  end

  @doc """
  Exchanges an authorization code for an access token.
  """
  @spec exchange_token(App.t(), Authorization.t()) ::
          {:ok, Token.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  def exchange_token(%App{} = app, %Authorization{} = auth) do
    with {:ok, auth} <- Authorization.use_token(auth),
         true <- auth.app_id == app.id do
      user = if auth.user_id, do: Repo.get(User, auth.user_id), else: nil

      create(app, user, %{scopes: auth.scopes})
    else
      false -> {:error, "app mismatch"}
      error -> error
    end
  end

  @doc """
  Gets a pre-existing valid token for an app and user.
  """
  @spec get_existing(App.t(), User.t()) :: {:ok, t()} | {:error, :not_found}
  def get_existing(%App{id: app_id}, %User{id: user_id}) do
    query =
      from(t in __MODULE__,
        where: t.app_id == ^app_id and t.user_id == ^user_id,
        where: t.valid_until > ^DateTime.utc_now(),
        order_by: [desc: t.inserted_at],
        limit: 1,
        preload: [:user, :app]
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      token -> {:ok, token}
    end
  end

  @doc """
  Gets or exchanges a token. If auth was already used, get existing token.
  """
  @spec get_or_exchange_token(Authorization.t(), App.t(), User.t()) ::
          {:ok, t()} | {:error, any()}
  def get_or_exchange_token(%Authorization{used: true}, %App{} = app, %User{} = user) do
    get_existing(app, user)
  end

  def get_or_exchange_token(%Authorization{} = auth, %App{} = app, _user) do
    exchange_token(app, auth)
  end

  @doc """
  Creates a new access token for an app and user.
  """
  @spec create(App.t(), User.t() | nil, map()) :: {:ok, Token.t()} | {:error, Ecto.Changeset.t()}
  def create(%App{} = app, user, attrs \\ %{}) do
    user_id = if user, do: user.id, else: nil

    %__MODULE__{user_id: user_id, app_id: app.id}
    |> cast(%{scopes: attrs[:scopes] || app.scopes}, [:scopes])
    |> validate_required([:scopes, :app_id])
    |> put_valid_until(attrs)
    |> put_token()
    |> put_refresh_token(attrs)
    |> Repo.insert()
  end

  @doc """
  Refreshes an existing token by creating a new one.
  """
  @spec refresh(App.t(), String.t()) :: {:ok, t()} | {:error, any()}
  def refresh(%App{} = app, refresh_token) do
    with {:ok, old_token} <- get_by_refresh_token(app, refresh_token) do
      # Delete the old token
      Repo.delete(old_token)

      # Create a new token with the same scopes
      create(app, old_token.user, %{scopes: old_token.scopes})
    end
  end

  @doc """
  Deletes all tokens for a user.
  """
  @spec delete_user_tokens(User.t()) :: {integer(), any()}
  def delete_user_tokens(%User{id: user_id}) do
    from(t in __MODULE__, where: t.user_id == ^user_id)
    |> Repo.delete_all()
  end

  @doc """
  Deletes a specific token for a user.
  """
  @spec delete_user_token(User.t(), integer()) :: {integer(), any()}
  def delete_user_token(%User{id: user_id}, token_id) do
    from(t in __MODULE__, where: t.user_id == ^user_id and t.id == ^token_id)
    |> Repo.delete_all()
  end

  @doc """
  Gets all tokens for a user.
  """
  @spec get_user_tokens(User.t()) :: [t()]
  def get_user_tokens(%User{id: user_id}) do
    from(t in __MODULE__,
      where: t.user_id == ^user_id,
      preload: [:app],
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Revokes (deletes) a token by its access token string.
  """
  @spec revoke(String.t()) :: :ok | {:error, :not_found}
  def revoke(token) do
    case from(t in __MODULE__, where: t.token == ^token) |> Repo.delete_all() do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  end

  @doc """
  Checks if a token is expired.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{valid_until: valid_until}) do
    DateTime.compare(DateTime.utc_now(), valid_until) == :gt
  end

  def expired?(_), do: true

  # Private functions

  defp put_valid_until(changeset, attrs) do
    valid_until =
      Map.get_lazy(attrs, :valid_until, fn ->
        DateTime.add(DateTime.utc_now(), lifespan(), :second)
      end)

    put_change(changeset, :valid_until, valid_until)
  end

  defp put_token(changeset) do
    token = generate_token()

    changeset
    |> put_change(:token, token)
    |> validate_required([:token])
    |> unique_constraint(:token)
  end

  defp put_refresh_token(changeset, attrs) do
    refresh_token = Map.get(attrs, :refresh_token, generate_token())

    changeset
    |> put_change(:refresh_token, refresh_token)
    |> validate_required([:refresh_token])
    |> unique_constraint(:refresh_token)
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
