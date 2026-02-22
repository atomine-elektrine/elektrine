defmodule Elektrine.OAuth.App do
  @moduledoc """
  OAuth application registration for Mastodon API clients.

  This module handles the registration and management of third-party applications
  that want to connect to the Mastodon-compatible API. Each app gets a unique
  client_id and client_secret that can be used to authenticate users.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  @type t :: %__MODULE__{}

  schema "oauth_apps" do
    field(:client_name, :string)
    field(:redirect_uris, :string)
    field(:scopes, {:array, :string}, default: ["read"])
    field(:website, :string)
    field(:client_id, :string)
    field(:client_secret, :string)
    field(:trusted, :boolean, default: false)

    belongs_to(:user, User)

    has_many(:oauth_authorizations, Elektrine.OAuth.Authorization, on_delete: :delete_all)
    has_many(:oauth_tokens, Elektrine.OAuth.Token, on_delete: :delete_all)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for updating an existing app.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(struct, params) do
    struct
    |> cast(params, [:client_name, :redirect_uris, :scopes, :website, :trusted, :user_id])
    |> validate_length(:client_name, max: 255)
    |> validate_length(:website, max: 2048)
  end

  @doc """
  Changeset for registering a new app. Generates client_id and client_secret.
  """
  @spec register_changeset(t(), map()) :: Ecto.Changeset.t()
  def register_changeset(struct, params \\ %{}) do
    changeset =
      struct
      |> changeset(params)
      |> validate_required([:client_name, :redirect_uris, :scopes])
      |> validate_redirect_uris()

    if changeset.valid? do
      changeset
      |> put_change(:client_id, generate_token())
      |> put_change(:client_secret, generate_token())
    else
      changeset
    end
  end

  @doc """
  Creates a new OAuth app.
  """
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(params) do
    %__MODULE__{}
    |> register_changeset(params)
    |> Repo.insert()
  end

  @doc """
  Updates an existing OAuth app.
  """
  @spec update(pos_integer(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()} | nil
  def update(id, params) do
    case Repo.get(__MODULE__, id) do
      %__MODULE__{} = app ->
        app
        |> changeset(params)
        |> Repo.update()

      nil ->
        nil
    end
  end

  @doc """
  Gets an app by client_id.
  """
  @spec get_by_client_id(String.t()) :: t() | nil
  def get_by_client_id(client_id) do
    Repo.get_by(__MODULE__, client_id: client_id)
  end

  @doc """
  Gets an app by client_id and client_secret.
  """
  @spec get_by_credentials(String.t(), String.t()) :: t() | nil
  def get_by_credentials(client_id, client_secret) do
    Repo.get_by(__MODULE__, client_id: client_id, client_secret: client_secret)
  end

  @doc """
  Gets an existing app or creates a new one with the given attributes.
  Updates scopes if the app already exists.
  """
  @spec get_or_create(map(), list(String.t())) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def get_or_create(attrs, scopes) do
    case Repo.get_by(__MODULE__, Map.take(attrs, [:client_name, :redirect_uris])) do
      %__MODULE__{} = app ->
        update_scopes(app, scopes)

      nil ->
        %__MODULE__{}
        |> register_changeset(Map.put(attrs, :scopes, scopes))
        |> Repo.insert()
    end
  end

  @doc """
  Gets all apps owned by a user.
  """
  @spec get_user_apps(User.t()) :: [t()]
  def get_user_apps(%User{id: user_id}) do
    from(a in __MODULE__, where: a.user_id == ^user_id)
    |> Repo.all()
  end

  @doc """
  Deletes an OAuth app.
  """
  @spec delete(pos_integer()) :: {:ok, t()} | {:error, Ecto.Changeset.t()} | nil
  def delete(id) do
    case Repo.get(__MODULE__, id) do
      %__MODULE__{} = app -> Repo.delete(app)
      nil -> nil
    end
  end

  @doc """
  Searches for apps with pagination and optional filters.
  """
  @spec search(map()) :: {:ok, [t()], non_neg_integer()}
  def search(params) do
    page = Map.get(params, :page, 1)
    page_size = Map.get(params, :page_size, 20)

    query = from(a in __MODULE__)

    query =
      if params[:client_name] do
        from(a in query, where: a.client_name == ^params[:client_name])
      else
        query
      end

    query =
      if params[:client_id] do
        from(a in query, where: a.client_id == ^params[:client_id])
      else
        query
      end

    query =
      if Map.has_key?(params, :trusted) do
        from(a in query, where: a.trusted == ^params[:trusted])
      else
        query
      end

    count = Repo.aggregate(__MODULE__, :count, :id)

    apps =
      from(a in query,
        limit: ^page_size,
        offset: ^((page - 1) * page_size),
        order_by: [desc: a.inserted_at]
      )
      |> Repo.all()

    {:ok, apps, count}
  end

  # Private functions

  defp update_scopes(%__MODULE__{scopes: current_scopes} = app, new_scopes)
       when current_scopes == new_scopes or new_scopes == [] do
    {:ok, app}
  end

  defp update_scopes(%__MODULE__{} = app, scopes) do
    app
    |> change(%{scopes: scopes})
    |> Repo.update()
  end

  defp validate_redirect_uris(changeset) do
    case get_change(changeset, :redirect_uris) do
      nil ->
        changeset

      uris ->
        uris
        |> String.split()
        |> Enum.all?(&valid_redirect_uri?/1)
        |> case do
          true -> changeset
          false -> add_error(changeset, :redirect_uris, "contains invalid URI")
        end
    end
  end

  defp valid_redirect_uri?("urn:ietf:wg:oauth:2.0:oob"), do: true

  defp valid_redirect_uri?(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
        true

      _ ->
        false
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
