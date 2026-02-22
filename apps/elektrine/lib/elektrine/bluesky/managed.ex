defmodule Elektrine.Bluesky.Managed do
  @moduledoc """
  Managed PDS account provisioning for Bluesky.

  This path allows the instance to:
  - Create invite codes with admin credentials
  - Create a per-user PDS account
  - Create an app password for bridge usage
  - Persist Bluesky linkage fields to the local user account
  """

  require Logger

  import Ecto.Query, warn: false

  alias Elektrine.Accounts
  alias Elektrine.Accounts.Authentication
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  @default_timeout_ms 12_000

  @doc """
  Provisions Bluesky for a local user on a managed PDS.
  """
  def enable_for_user(%User{} = user, current_password) when is_binary(current_password) do
    with :ok <- ensure_managed_enabled(),
         {:ok, _verified_user} <- Authentication.verify_user_password(user, current_password),
         :ok <- ensure_not_already_enabled(user),
         {:ok, service_url} <- managed_service_url(),
         {:ok, handle_domain} <- managed_domain(),
         {:ok, admin_password} <- managed_admin_password(),
         {:ok, invite_code} <- create_invite_code(service_url, admin_password),
         {:ok, account} <-
           create_account(service_url, invite_code, user, current_password, handle_domain),
         {:ok, session} <- create_session(service_url, account["did"], current_password),
         {:ok, app_password} <-
           create_app_password(service_url, session.access_jwt, user.username),
         {:ok, updated_user} <- persist_user_link(user, account, app_password, service_url) do
      {:ok,
       %{
         user: updated_user,
         did: account["did"],
         handle: account["handle"]
       }}
    else
      {:error, reason} = error ->
        Logger.warning("Managed Bluesky enable failed for user #{user.id}: #{inspect(reason)}")
        error
    end
  end

  def enable_for_user(%User{}, _current_password), do: {:error, :current_password_required}

  @doc """
  Reconnects (or refreshes) managed Bluesky credentials for a local user.
  """
  def reconnect_for_user(%User{} = user, current_password) when is_binary(current_password) do
    with :ok <- ensure_managed_enabled(),
         {:ok, _verified_user} <- Authentication.verify_user_password(user, current_password),
         {:ok, service_url} <- managed_service_url(),
         {:ok, handle_domain} <- managed_domain(),
         {:ok, identifier} <- reconnect_identifier(user, handle_domain),
         {:ok, session} <- create_session(service_url, identifier, current_password),
         {:ok, app_password} <-
           create_app_password(service_url, session.access_jwt, user.username),
         {:ok, updated_user} <-
           persist_reconnect_link(user, session, identifier, app_password, service_url) do
      {:ok,
       %{
         user: updated_user,
         did: session.did,
         handle: session.handle || fallback_handle(identifier, user.username, handle_domain)
       }}
    else
      {:error, reason} = error ->
        Logger.warning("Managed Bluesky reconnect failed for user #{user.id}: #{inspect(reason)}")
        error
    end
  end

  def reconnect_for_user(%User{}, _current_password), do: {:error, :current_password_required}

  @doc """
  Disconnects managed Bluesky linkage for a local user.
  """
  def disconnect_for_user(%User{} = user, current_password) when is_binary(current_password) do
    with {:ok, _verified_user} <- Authentication.verify_user_password(user, current_password),
         {1, _} <-
           from(u in User, where: u.id == ^user.id)
           |> Repo.update_all(
             set: [
               bluesky_enabled: false,
               bluesky_identifier: nil,
               bluesky_app_password: nil,
               bluesky_did: nil,
               bluesky_pds_url: nil,
               bluesky_inbound_cursor: nil,
               bluesky_inbound_last_polled_at: nil
             ]
           ) do
      {:ok, Repo.get!(User, user.id)}
    else
      {0, _} ->
        {:error, :user_not_found}

      {:error, reason} = error ->
        Logger.warning(
          "Managed Bluesky disconnect failed for user #{user.id}: #{inspect(reason)}"
        )

        error
    end
  end

  def disconnect_for_user(%User{}, _current_password), do: {:error, :current_password_required}

  defp ensure_managed_enabled do
    if Keyword.get(bluesky_config(), :managed_enabled, false) do
      :ok
    else
      {:error, :managed_pds_disabled}
    end
  end

  defp ensure_not_already_enabled(%User{bluesky_enabled: true, bluesky_app_password: password})
       when is_binary(password) and password != "" do
    {:error, :already_enabled}
  end

  defp ensure_not_already_enabled(_user), do: :ok

  defp managed_service_url do
    configured =
      Keyword.get(bluesky_config(), :managed_service_url) ||
        Keyword.get(bluesky_config(), :service_url, "https://bsky.social")

    normalize_service_url(configured)
  end

  defp managed_domain do
    case Keyword.get(bluesky_config(), :managed_domain) do
      value when is_binary(value) ->
        domain = String.trim(value)
        if domain == "", do: {:error, :missing_managed_domain}, else: {:ok, domain}

      _ ->
        {:error, :missing_managed_domain}
    end
  end

  defp managed_admin_password do
    case Keyword.get(bluesky_config(), :managed_admin_password) do
      value when is_binary(value) ->
        password = String.trim(value)
        if password == "", do: {:error, :missing_managed_admin_password}, else: {:ok, password}

      _ ->
        {:error, :missing_managed_admin_password}
    end
  end

  defp normalize_service_url(url) when is_binary(url) do
    normalized =
      url
      |> String.trim()
      |> maybe_add_scheme()
      |> String.trim_trailing("/")

    case URI.parse(normalized) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, normalized}

      _ ->
        {:error, :invalid_managed_service_url}
    end
  end

  defp normalize_service_url(_), do: {:error, :invalid_managed_service_url}

  defp maybe_add_scheme(url) do
    if String.starts_with?(url, ["http://", "https://"]) do
      url
    else
      "https://" <> url
    end
  end

  defp create_invite_code(service_url, admin_password) do
    url = service_url <> "/xrpc/com.atproto.server.createInviteCode"
    headers = managed_admin_headers(admin_password)
    payload = %{"useCount" => 1}

    with {:ok, response} <- request_json(:post, url, payload, headers),
         :ok <- require_success_status(response.status, :create_invite_code_failed),
         {:ok, body} <- decode_json_body(response.body),
         {:ok, code} <- map_fetch_string(body, "code", :missing_invite_code) do
      {:ok, code}
    end
  end

  defp create_account(service_url, invite_code, user, password, handle_domain) do
    url = service_url <> "/xrpc/com.atproto.server.createAccount"
    handle = "#{user.username}.#{handle_domain}"
    email = user.recovery_email || default_pds_email(user)

    payload = %{
      "email" => email,
      "handle" => handle,
      "password" => password,
      "inviteCode" => invite_code
    }

    with {:ok, response} <- request_json(:post, url, payload, []),
         :ok <- require_success_status(response.status, :create_account_failed),
         {:ok, body} <- decode_json_body(response.body),
         {:ok, _did} <- map_fetch_string(body, "did", :missing_did),
         {:ok, _handle} <- map_fetch_string(body, "handle", :missing_handle) do
      {:ok, body}
    end
  end

  defp create_session(service_url, identifier, password) do
    url = service_url <> "/xrpc/com.atproto.server.createSession"
    payload = %{"identifier" => identifier, "password" => password}

    with {:ok, response} <- request_json(:post, url, payload, []),
         :ok <- require_success_status(response.status, :create_session_failed),
         {:ok, body} <- decode_json_body(response.body),
         {:ok, access_jwt} <- map_fetch_string(body, "accessJwt", :missing_access_jwt),
         {:ok, did} <- map_fetch_string(body, "did", :missing_did) do
      {:ok, %{access_jwt: access_jwt, did: did, handle: body["handle"]}}
    end
  end

  defp create_app_password(service_url, access_jwt, username) do
    url = service_url <> "/xrpc/com.atproto.server.createAppPassword"
    headers = [{"authorization", "Bearer " <> access_jwt}]
    create_app_password_with_retry(url, headers, username, 1)
  end

  defp extract_app_password(body) when is_map(body) do
    case body["password"] || body["appPassword"] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_app_password}
    end
  end

  defp extract_app_password(_), do: {:error, :missing_app_password}

  defp create_app_password_with_retry(url, headers, username, retries_left) do
    payload = %{
      "name" => app_password_name(username)
    }

    with {:ok, response} <- request_json(:post, url, payload, headers),
         :ok <- require_success_status(response.status, :create_app_password_failed),
         {:ok, body} <- decode_json_body(response.body),
         {:ok, app_password} <- extract_app_password(body) do
      {:ok, app_password}
    else
      {:error, {:create_app_password_failed, 500}} when retries_left > 0 ->
        create_app_password_with_retry(url, headers, username, retries_left - 1)

      error ->
        error
    end
  end

  defp app_password_name(username) do
    base =
      username
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "")
      |> case do
        "" -> "user"
        value -> value
      end
      |> String.slice(0, 16)

    suffix =
      :erlang.unique_integer([:positive, :monotonic])
      |> Integer.to_string(36)

    "elektrine-#{base}-#{suffix}"
  end

  defp persist_user_link(user, account, app_password, service_url) do
    did = account["did"]

    attrs = %{
      bluesky_enabled: true,
      bluesky_identifier: did || account["handle"],
      bluesky_app_password: app_password,
      bluesky_pds_url: service_url,
      bluesky_inbound_cursor: nil
    }

    case Accounts.update_user(user, attrs) do
      {:ok, updated_user} ->
        if is_binary(did) and did != "" do
          from(u in User, where: u.id == ^updated_user.id)
          |> Repo.update_all(set: [bluesky_did: did])
        end

        {:ok, Repo.get!(User, updated_user.id)}

      error ->
        error
    end
  end

  defp persist_reconnect_link(user, session, identifier, app_password, service_url) do
    did = session.did

    identifier_value =
      if is_binary(did) and did != "" do
        did
      else
        identifier
      end

    attrs = %{
      bluesky_enabled: true,
      bluesky_identifier: identifier_value,
      bluesky_app_password: app_password,
      bluesky_pds_url: service_url,
      bluesky_inbound_cursor: nil
    }

    case Accounts.update_user(user, attrs) do
      {:ok, updated_user} ->
        if is_binary(did) and did != "" do
          from(u in User, where: u.id == ^updated_user.id)
          |> Repo.update_all(set: [bluesky_did: did])
        end

        {:ok, Repo.get!(User, updated_user.id)}

      error ->
        error
    end
  end

  defp reconnect_identifier(%User{} = user, handle_domain) do
    candidate =
      [user.bluesky_did, user.bluesky_identifier, "#{user.username}.#{handle_domain}"]
      |> Enum.find(fn value -> is_binary(value) and String.trim(value) != "" end)

    case candidate do
      value when is_binary(value) -> {:ok, String.trim(value)}
      _ -> {:error, :missing_identifier}
    end
  end

  defp fallback_handle("did:" <> _did, username, handle_domain),
    do: "#{username}.#{handle_domain}"

  defp fallback_handle(handle, _username, _handle_domain), do: handle

  defp request_json(method, url, payload, extra_headers) do
    headers =
      [
        {"content-type", "application/json"},
        {"accept", "application/json"}
        | extra_headers
      ]

    body = Jason.encode!(payload)
    timeout_ms = Keyword.get(bluesky_config(), :timeout_ms, @default_timeout_ms)
    request_opts = [receive_timeout: timeout_ms]

    request_with_retry(method, url, headers, body, request_opts)
  end

  defp request_with_retry(method, url, headers, body, opts, retries_left \\ 1) do
    case http_client().request(method, url, headers, body, opts) do
      {:ok, %Finch.Response{} = response} ->
        {:ok, response}

      {:error, reason} ->
        cond do
          retries_left > 0 and retryable_transport_closed?(reason) ->
            request_with_retry(method, url, headers, body, opts, retries_left - 1)

          true ->
            {:error, {:http_error, reason}}
        end
    end
  end

  defp retryable_transport_closed?(%Mint.TransportError{reason: :closed}), do: true
  defp retryable_transport_closed?(:closed), do: true
  defp retryable_transport_closed?(_reason), do: false

  defp managed_admin_headers(admin_password) do
    token = Base.encode64("admin:" <> admin_password)
    [{"authorization", "Basic " <> token}]
  end

  defp require_success_status(status, _reason) when status in 200..299, do: :ok
  defp require_success_status(status, reason), do: {:error, {reason, status}}

  defp decode_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_json_body(_), do: {:error, :invalid_json}

  defp map_fetch_string(map, key, reason) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, reason}
    end
  end

  defp map_fetch_string(_map, _key, reason), do: {:error, reason}

  defp default_pds_email(user) do
    email_domain =
      Application.get_env(:elektrine, :email, [])
      |> Keyword.get(:domain, "elektrine.local")

    "#{user.username}@#{email_domain}"
  end

  defp bluesky_config, do: Application.get_env(:elektrine, :bluesky, [])

  defp http_client do
    Keyword.get(bluesky_config(), :http_client, Elektrine.Bluesky.FinchClient)
  end
end
