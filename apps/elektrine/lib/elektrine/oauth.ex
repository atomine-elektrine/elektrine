defmodule Elektrine.OAuth do
  @moduledoc """
  The OAuth context for Mastodon API compatibility.

  This module provides OAuth 2.0 functionality for third-party apps
  to authenticate with the Mastodon-compatible API.
  """

  alias Elektrine.OAuth.App
  alias Elektrine.OAuth.Authorization
  alias Elektrine.OAuth.Token
  alias Elektrine.OAuth.Scopes
  alias Elektrine.Accounts.User

  # Re-export key modules
  defdelegate valid_scopes, to: Scopes
  defdelegate parse_scopes(scope_string, default \\ ["read"]), to: Scopes
  defdelegate fetch_scopes(params, default \\ ["read"]), to: Scopes

  # App functions

  @doc """
  Creates a new OAuth app.
  """
  @spec create_app(map()) :: {:ok, App.t()} | {:error, Ecto.Changeset.t()}
  def create_app(params), do: App.create(params)

  @doc """
  Gets an app by its client_id.
  """
  @spec get_app_by_client_id(String.t()) :: App.t() | nil
  def get_app_by_client_id(client_id), do: App.get_by_client_id(client_id)

  @doc """
  Gets an app by its credentials (client_id and client_secret).
  """
  @spec get_app_by_credentials(String.t(), String.t()) :: App.t() | nil
  def get_app_by_credentials(client_id, client_secret) do
    App.get_by_credentials(client_id, client_secret)
  end

  @doc """
  Gets all apps owned by a user.
  """
  @spec get_user_apps(User.t()) :: [App.t()]
  def get_user_apps(user), do: App.get_user_apps(user)

  @doc """
  Deletes an OAuth app.
  """
  @spec delete_app(integer()) :: {:ok, App.t()} | {:error, Ecto.Changeset.t()} | nil
  def delete_app(id), do: App.delete(id)

  # Authorization functions

  @doc """
  Creates an authorization code for the OAuth flow.
  """
  @spec create_authorization(App.t(), User.t(), [String.t()] | nil) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()}
  def create_authorization(app, user, scopes \\ nil) do
    Authorization.create_authorization(app, user, scopes)
  end

  @doc """
  Gets an authorization by its token for a specific app.
  """
  @spec get_authorization(App.t(), String.t()) :: {:ok, Authorization.t()} | {:error, :not_found}
  def get_authorization(app, token), do: Authorization.get_by_token(app, token)

  # Token functions

  @doc """
  Creates an access token directly (for password grant or client credentials).
  """
  @spec create_token(App.t(), User.t() | nil, map()) ::
          {:ok, Token.t()} | {:error, Ecto.Changeset.t()}
  def create_token(app, user, attrs \\ %{}), do: Token.create(app, user, attrs)

  @doc """
  Exchanges an authorization code for an access token.
  """
  @spec exchange_token(App.t(), Authorization.t()) ::
          {:ok, Token.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  def exchange_token(app, auth), do: Token.exchange_token(app, auth)

  @doc """
  Gets a token by its access token string.
  """
  @spec get_token(String.t()) :: {:ok, Token.t()} | {:error, :not_found}
  def get_token(token), do: Token.get_by_token(token)

  @doc """
  Gets all tokens for a user.
  """
  @spec get_user_tokens(User.t()) :: [Token.t()]
  def get_user_tokens(user), do: Token.get_user_tokens(user)

  @doc """
  Refreshes an access token using a refresh token.
  """
  @spec refresh_token(App.t(), String.t()) :: {:ok, Token.t()} | {:error, any()}
  def refresh_token(app, refresh_token), do: Token.refresh(app, refresh_token)

  @doc """
  Revokes an access token.
  """
  @spec revoke_token(String.t()) :: :ok | {:error, :not_found}
  def revoke_token(token), do: Token.revoke(token)

  @doc """
  Deletes all tokens and authorizations for a user.
  """
  @spec delete_user_tokens(User.t()) :: :ok
  def delete_user_tokens(user) do
    Token.delete_user_tokens(user)
    Authorization.delete_user_authorizations(user)
    :ok
  end

  @doc """
  Validates that a token has the required scopes.
  """
  @spec validate_scopes(Token.t(), [String.t()]) :: :ok | {:error, :insufficient_scope}
  def validate_scopes(%Token{scopes: token_scopes}, required_scopes) do
    if Scopes.all_satisfied?(token_scopes, required_scopes) do
      :ok
    else
      {:error, :insufficient_scope}
    end
  end

  @doc """
  Checks if a token is valid (not expired).
  """
  @spec token_valid?(Token.t()) :: boolean()
  def token_valid?(%Token{} = token), do: not Token.expired?(token)
  def token_valid?(_), do: false
end
