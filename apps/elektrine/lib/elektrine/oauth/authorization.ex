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
    field(:plain_token, :string, virtual: true)
    field(:scopes, {:array, :string}, default: [])
    field(:valid_until, :utc_datetime)
    field(:used, :boolean, default: false)
    field(:redirect_uri, :string)
    field(:state, :string)
    field(:nonce, :string)
    field(:code_challenge, :string)
    field(:code_challenge_method, :string)

    belongs_to(:user, User)
    belongs_to(:app, App, foreign_key: :app_id)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a new authorization for the given app and user.
  """
  @spec create_authorization(App.t(), User.t(), [String.t()] | map() | nil) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()}
  def create_authorization(%App{} = app, %User{} = user, attrs_or_scopes \\ nil) do
    attrs =
      case attrs_or_scopes do
        nil -> %{}
        scopes when is_list(scopes) -> %{scopes: scopes}
        attrs when is_map(attrs) -> attrs
      end

    attrs
    |> Map.put_new(:scopes, app.scopes)
    |> Map.put(:user_id, user.id)
    |> Map.put(:app_id, app.id)
    |> create_changeset()
    |> Repo.insert()
  end

  @doc """
  Creates a changeset for a new authorization.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs \\ %{}) do
    %Authorization{}
    |> cast(attrs, [
      :user_id,
      :app_id,
      :scopes,
      :valid_until,
      :redirect_uri,
      :state,
      :nonce,
      :code_challenge,
      :code_challenge_method
    ])
    |> validate_required([:app_id, :scopes])
    |> validate_inclusion(:code_challenge_method, ["S256"])
    |> validate_code_challenge_requirements()
    |> add_token()
    |> add_lifetime()
  end

  @doc """
  Atomically consumes an authorization code and returns it if valid.
  """
  @spec consume_token(App.t(), String.t()) :: {:ok, t()} | {:error, :not_found | String.t()}
  def consume_token(%App{id: app_id}, token) do
    Repo.transaction(fn ->
      query =
        from(a in __MODULE__,
          where: a.app_id == ^app_id and a.token == ^hash_secret(token),
          where: a.used == false and a.valid_until > ^DateTime.utc_now(),
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        auth ->
          case Repo.update(use_changeset(auth, %{used: true})) do
            {:ok, used_auth} -> used_auth
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, auth} -> {:ok, auth}
      {:error, :not_found} -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets an authorization by token for a specific app.
  """
  @spec get_by_token(App.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_by_token(%App{id: app_id}, token) do
    query = from(a in __MODULE__, where: a.app_id == ^app_id and a.token == ^hash_secret(token))

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

  @doc """
  Deletes all authorizations for a user and app.
  """
  @spec delete_user_app_authorizations(User.t(), pos_integer()) :: {integer(), any()}
  def delete_user_app_authorizations(%User{id: user_id}, app_id) do
    from(a in __MODULE__, where: a.user_id == ^user_id and a.app_id == ^app_id)
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

    changeset
    |> put_change(:token, hash_secret(token))
    |> put_change(:plain_token, token)
  end

  defp add_lifetime(changeset) do
    valid_until =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(@authorization_lifetime, :second)

    put_change(changeset, :valid_until, valid_until)
  end

  def token_value(%Authorization{plain_token: token}) when is_binary(token), do: token
  def token_value(_), do: nil

  defp hash_secret(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
  end

  defp validate_code_challenge_requirements(changeset) do
    code_challenge = get_field(changeset, :code_challenge)
    code_challenge_method = get_field(changeset, :code_challenge_method)

    cond do
      is_binary(code_challenge) and code_challenge != "" and is_nil(code_challenge_method) ->
        put_change(changeset, :code_challenge_method, "S256")

      is_binary(code_challenge_method) and code_challenge_method != "" and
          not is_binary(code_challenge) ->
        add_error(changeset, :code_challenge, "is required when code_challenge_method is set")

      true ->
        changeset
    end
  end
end
