defmodule Elektrine.OAuth.Token do
  @moduledoc """
  OAuth access tokens for the Mastodon API.

  Access tokens are long-lived tokens that authenticate API requests.
  They can be obtained through the OAuth authorization code flow.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.Accounts.{Authentication, User}
  alias Elektrine.OAuth.App
  alias Elektrine.OAuth.Authorization
  alias Elektrine.OAuth.Token
  alias Elektrine.Repo

  @type t :: %__MODULE__{}

  # Default token lifetime: 30 days
  @default_token_lifetime 30 * 24 * 60 * 60
  @default_refresh_token_lifetime 30 * 24 * 60 * 60

  schema "oauth_tokens" do
    field(:token, :string)
    field(:refresh_token, :string)
    field(:plain_token, :string, virtual: true)
    field(:plain_refresh_token, :string, virtual: true)
    field(:scopes, {:array, :string}, default: [])
    field(:valid_until, :utc_datetime)
    field(:oidc_nonce, :string)
    field(:oidc_auth_time, :utc_datetime)

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
    query =
      from(t in __MODULE__,
        where: t.token == ^hash_secret(token),
        preload: [:user, :app]
      )

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
        where: t.app_id == ^app_id and t.token == ^hash_secret(token),
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
        where: t.app_id == ^app_id and t.refresh_token == ^hash_secret(refresh_token),
        where: t.valid_until > ^DateTime.utc_now(),
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
    if auth.app_id == app.id do
      user = if auth.user_id, do: Repo.get(User, auth.user_id), else: nil

      if token_older_than_auth_boundary?(user, auth) do
        {:error, "authorization code invalidated"}
      else
        create(app, user, %{
          scopes: auth.scopes,
          oidc_nonce: auth.nonce,
          oidc_auth_time: auth.inserted_at
        })
      end
    else
      {:error, "app mismatch"}
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
    with :ok <- ensure_active_user(user),
         :ok <- validate_requested_scopes(attrs[:scopes] || app.scopes, app.scopes) do
      user_id = if user, do: user.id, else: nil

      %__MODULE__{user_id: user_id, app_id: app.id}
      |> cast(%{scopes: attrs[:scopes] || app.scopes}, [:scopes])
      |> validate_required([:scopes, :app_id])
      |> put_valid_until(attrs)
      |> put_oidc_attrs(attrs)
      |> put_token()
      |> put_refresh_token(attrs)
      |> Repo.insert()
      |> case do
        {:ok, token} -> {:ok, Repo.preload(token, [:user, :app])}
        error -> error
      end
    end
  end

  @doc """
  Refreshes an existing token by creating a new one.
  """
  @spec refresh(App.t(), String.t()) :: {:ok, t()} | {:error, any()}
  def refresh(%App{} = app, refresh_token) do
    Repo.transaction(fn ->
      query =
        from(t in __MODULE__,
          where: t.app_id == ^app.id and t.refresh_token == ^hash_secret(refresh_token),
          where: t.valid_until > ^DateTime.utc_now(),
          lock: "FOR UPDATE",
          preload: [:user, :app]
        )

      with %__MODULE__{} = old_token <- Repo.one(query),
           :ok <- ensure_active_user(old_token.user),
           false <- token_older_than_auth_boundary?(old_token.user, old_token),
           {1, _} <- Repo.delete_all(from(t in __MODULE__, where: t.id == ^old_token.id)),
           {:ok, new_token} <-
             create(app, old_token.user, %{
               scopes: old_token.scopes,
               oidc_nonce: old_token.oidc_nonce,
               oidc_auth_time: old_token.oidc_auth_time
             }) do
        new_token
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
        {0, _} -> Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, reason}
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
  Gets all tokens granted by a user to a specific app.
  """
  @spec get_user_app_tokens(User.t(), pos_integer()) :: [t()]
  def get_user_app_tokens(%User{id: user_id}, app_id) do
    from(t in __MODULE__,
      where: t.user_id == ^user_id and t.app_id == ^app_id,
      preload: [:app],
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Deletes all tokens for a user granted to a specific app.
  """
  @spec delete_user_app_tokens(User.t(), pos_integer()) :: {integer(), any()}
  def delete_user_app_tokens(%User{id: user_id}, app_id) do
    from(t in __MODULE__, where: t.user_id == ^user_id and t.app_id == ^app_id)
    |> Repo.delete_all()
  end

  @doc """
  Revokes (deletes) a token by its access token string.
  """
  @spec revoke(String.t()) :: :ok | {:error, :not_found}
  def revoke(token) do
    case from(t in __MODULE__,
           where: t.token == ^hash_secret(token) or t.refresh_token == ^hash_secret(token)
         )
         |> Repo.delete_all() do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  end

  @spec revoke(App.t(), String.t()) :: :ok | {:error, :not_found}
  def revoke(%App{id: app_id}, token) do
    case from(t in __MODULE__,
           where:
             t.app_id == ^app_id and
               (t.token == ^hash_secret(token) or t.refresh_token == ^hash_secret(token))
         )
         |> Repo.delete_all() do
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

  defp ensure_active_user(nil), do: :ok

  defp ensure_active_user(%User{} = user) do
    Authentication.ensure_user_active(user)
  end

  defp token_older_than_auth_boundary?(%User{auth_valid_after: %DateTime{} = valid_after}, token) do
    DateTime.compare(token.inserted_at, valid_after) == :lt
  end

  defp token_older_than_auth_boundary?(_, _), do: false

  # Private functions

  defp put_valid_until(changeset, attrs) do
    valid_until =
      Map.get_lazy(attrs, :valid_until, fn ->
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> DateTime.add(min(lifespan(), refresh_token_lifetime()), :second)
      end)

    put_change(changeset, :valid_until, valid_until)
  end

  defp put_oidc_attrs(changeset, attrs) do
    changeset
    |> put_change(:oidc_nonce, Map.get(attrs, :oidc_nonce))
    |> put_change(:oidc_auth_time, truncate_datetime(Map.get(attrs, :oidc_auth_time)))
  end

  defp put_token(changeset) do
    token = generate_token()

    changeset
    |> put_change(:token, hash_secret(token))
    |> put_change(:plain_token, token)
    |> validate_required([:token])
    |> unique_constraint(:token)
  end

  defp put_refresh_token(changeset, attrs) do
    refresh_token = Map.get(attrs, :refresh_token, generate_token())

    changeset
    |> put_change(:refresh_token, hash_secret(refresh_token))
    |> put_change(:plain_refresh_token, refresh_token)
    |> validate_required([:refresh_token])
    |> unique_constraint(:refresh_token)
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  def access_token_value(%__MODULE__{plain_token: token}) when is_binary(token), do: token
  def access_token_value(_), do: nil

  def refresh_token_value(%__MODULE__{plain_refresh_token: token}) when is_binary(token),
    do: token

  def refresh_token_value(_), do: nil

  defp hash_secret(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
  end

  defp truncate_datetime(%DateTime{} = datetime), do: DateTime.truncate(datetime, :second)
  defp truncate_datetime(value), do: value

  defp validate_requested_scopes(requested_scopes, allowed_scopes) do
    requested = MapSet.new(List.wrap(requested_scopes))
    allowed = MapSet.new(List.wrap(allowed_scopes))

    if MapSet.subset?(requested, allowed) do
      :ok
    else
      {:error, :invalid_scope}
    end
  end

  defp refresh_token_lifetime do
    Application.get_env(
      :elektrine,
      :oauth_refresh_token_lifetime,
      @default_refresh_token_lifetime
    )
  end
end
