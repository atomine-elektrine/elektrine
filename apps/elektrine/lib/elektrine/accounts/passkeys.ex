defmodule Elektrine.Accounts.Passkeys do
  @moduledoc ~s|Context module for WebAuthn/Passkey management.\n\nProvides functions for:\n- Registering new passkeys\n- Authenticating with passkeys\n- Managing user's passkeys (list, rename, delete)\n|
  import Ecto.Query, warn: false
  alias Elektrine.Accounts.{PasskeyCredential, User}
  alias Elektrine.AppCache
  alias Elektrine.Repo
  require Logger
  @challenge_timeout 300_000
  @doc ~s|Generate a registration challenge for adding a new passkey.\n\nReturns {:ok, challenge_data} or {:error, reason}\n\nThe challenge_data contains all information needed by the browser's\nWebAuthn API to create a new credential.\n\nOptions:\n  - :host - The request host (e.g., \"z.org\" or \"elektrine.com\") for multi-domain support\n|
  def generate_registration_challenge(user, opts \\ []) do
    passkey_count = count_user_passkeys(user)

    if passkey_count >= PasskeyCredential.max_passkeys_per_user() do
      {:error, :passkey_limit_reached}
    else
      user_handle = get_or_generate_user_handle(user)
      exclude_credentials = list_credential_ids_for_user(user)
      rp_id = get_rp_id(opts[:host])
      origin = get_origin(opts[:host])

      challenge_opts = [
        origin: origin,
        rp_id: rp_id,
        attestation: "none",
        user_verification: "preferred",
        timeout: div(@challenge_timeout, 1000)
      ]

      challenge = Wax.new_registration_challenge(challenge_opts)

      {:ok,
       %{
         challenge: challenge,
         challenge_b64: Base.url_encode64(challenge.bytes, padding: false),
         rp_id: rp_id,
         rp_name: "Elektrine",
         user_id: Base.url_encode64(user_handle, padding: false),
         user_name: user.username,
         user_display_name: user.display_name || user.username,
         timeout: @challenge_timeout,
         attestation: "none",
         authenticator_selection: %{resident_key: "preferred", user_verification: "preferred"},
         exclude_credentials:
           Enum.map(exclude_credentials, fn cred_id ->
             %{type: "public-key", id: Base.url_encode64(cred_id, padding: false)}
           end),
         pub_key_cred_params: [%{type: "public-key", alg: -7}, %{type: "public-key", alg: -257}]
       }}
    end
  end

  @doc ~s|Complete passkey registration by verifying the attestation.\n\nThe attestation_response is expected to be a map with the following structure:\n- \"response\" => %{\n    \"clientDataJSON\" => base64url encoded JSON string\n    \"attestationObject\" => base64url encoded CBOR binary\n    \"transports\" => optional list of transports\n  }\n\nReturns {:ok, credential} or {:error, reason}\n|
  def complete_registration(user, challenge, attestation_response, metadata \\ %{}) do
    response = attestation_response["response"] || %{}

    with {:ok, client_data_json_raw} <- decode_base64url(response["clientDataJSON"]),
         {:ok, attestation_object_cbor} <- decode_base64url(response["attestationObject"]),
         {:ok, {authenticator_data, _attestation_result}} <-
           Wax.register(attestation_object_cbor, client_data_json_raw, challenge) do
      credential_id = authenticator_data.attested_credential_data.credential_id
      public_key = authenticator_data.attested_credential_data.credential_public_key
      sign_count = authenticator_data.sign_count
      aaguid = authenticator_data.attested_credential_data.aaguid
      user_handle = get_or_generate_user_handle(user)
      transports = response["transports"] || []

      attrs = %{
        user_id: user.id,
        credential_id: credential_id,
        public_key: :erlang.term_to_binary(public_key),
        sign_count: sign_count,
        user_handle: user_handle,
        aaguid: aaguid,
        transports: transports,
        name: metadata[:name] || generate_passkey_name(user),
        created_from_ip: metadata[:ip],
        created_user_agent: metadata[:user_agent]
      }

      %PasskeyCredential{} |> PasskeyCredential.create_changeset(attrs) |> Repo.insert()
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc ~s|Generate an authentication challenge for passkey login.\n\nFor discoverable credentials (passkey login without username):\n- Pass nil for user\n- Browser will prompt user to select a passkey\n\nFor non-discoverable credentials (after username entry):\n- Pass the user struct\n- Challenge will include allowed credentials for that user\n\nOptions:\n  - :host - The request host (e.g., \"z.org\" or \"elektrine.com\") for multi-domain support\n|
  def generate_authentication_challenge(user \\ nil, opts \\ []) do
    rp_id = get_rp_id(opts[:host])
    origin = get_origin(opts[:host])

    allowed_credentials =
      case user do
        nil ->
          []

        %User{} = user ->
          user
          |> list_user_passkeys()
          |> Enum.reduce([], fn cred, acc ->
            case decode_public_key(cred.public_key) do
              {:ok, public_key} ->
                [{cred.credential_id, public_key} | acc]

              {:error, reason} ->
                Logger.warning(
                  "Skipping invalid passkey key for credential #{inspect(cred.id)}: #{inspect(reason)}"
                )

                acc
            end
          end)
          |> Enum.reverse()
      end

    challenge_opts = [
      origin: origin,
      rp_id: rp_id,
      user_verification: "preferred",
      timeout: div(@challenge_timeout, 1000),
      allow_credentials: allowed_credentials
    ]

    challenge = Wax.new_authentication_challenge(challenge_opts)

    allow_credentials_for_client =
      case user do
        nil ->
          []

        %User{} = u ->
          u
          |> list_user_passkeys()
          |> Enum.map(fn cred ->
            %{
              type: "public-key",
              id: Base.url_encode64(cred.credential_id, padding: false),
              transports: cred.transports
            }
          end)
      end

    AppCache.put_passkey_challenge(challenge.bytes, challenge)

    {:ok,
     %{
       challenge: challenge,
       challenge_b64: Base.url_encode64(challenge.bytes, padding: false),
       rp_id: rp_id,
       timeout: @challenge_timeout,
       user_verification: "preferred",
       allow_credentials: allow_credentials_for_client
     }}
  end

  @doc ~s|Retrieve a stored challenge from cache.\nUsed by the controller to get the full challenge struct for verification.\n|
  def get_challenge(challenge_bytes) when is_binary(challenge_bytes) do
    AppCache.get_passkey_challenge(challenge_bytes)
  end

  @doc ~s|Verify passkey authentication assertion.\n\nThe assertion_response is expected to be a map with:\n- \"id\" or \"rawId\" => base64url encoded credential ID\n- \"response\" => %{\n    \"clientDataJSON\" => base64url encoded JSON string\n    \"authenticatorData\" => base64url encoded binary\n    \"signature\" => base64url encoded binary\n  }\n\nReturns {:ok, user} or {:error, reason}\n|
  def verify_authentication(challenge, assertion_response) do
    credential_id_b64 = assertion_response["id"] || assertion_response["rawId"]
    response = assertion_response["response"] || %{}

    with {:ok, credential_id} <- decode_base64url(credential_id_b64),
         {:ok, client_data_json_raw} <- decode_base64url(response["clientDataJSON"]),
         {:ok, authenticator_data_bin} <- decode_base64url(response["authenticatorData"]),
         {:ok, signature} <- decode_base64url(response["signature"]) do
      case get_credential_by_id(credential_id) do
        nil ->
          {:error, :credential_not_found}

        credential ->
          case decode_public_key(credential.public_key) do
            {:ok, public_key} ->
              credentials = [{credential_id, public_key}]

              case Wax.authenticate(
                     credential_id,
                     authenticator_data_bin,
                     signature,
                     client_data_json_raw,
                     challenge,
                     credentials
                   ) do
                {:ok, authenticator_data} ->
                  new_sign_count = authenticator_data.sign_count

                  if new_sign_count > 0 and new_sign_count <= credential.sign_count do
                    Logger.warning(
                      "Passkey clone detection: credential #{inspect(credential.id)} " <>
                        "sign_count did not increase (stored: #{credential.sign_count}, received: #{new_sign_count})"
                    )

                    {:error, :cloned_authenticator}
                  else
                    credential
                    |> PasskeyCredential.update_sign_count_changeset(new_sign_count)
                    |> Repo.update()

                    user = Repo.get!(User, credential.user_id)
                    {:ok, user}
                  end

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, reason} ->
              Logger.warning(
                "Invalid passkey key for credential #{inspect(credential.id)}: #{inspect(reason)}"
              )

              {:error, :invalid_credential_key}
          end
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc ~s|List all passkeys for a user|
  def list_user_passkeys(%User{id: user_id}) do
    PasskeyCredential
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at)
    |> Repo.all()
  end

  @doc ~s|Count passkeys for a user|
  def count_user_passkeys(%User{id: user_id}) do
    PasskeyCredential |> where([p], p.user_id == ^user_id) |> Repo.aggregate(:count, :id)
  end

  @doc ~s|Check if user has any passkeys registered|
  def has_passkeys?(%User{} = user) do
    count_user_passkeys(user) > 0
  end

  @doc ~s|Get a specific passkey by ID, scoped to user|
  def get_user_passkey(%User{id: user_id}, passkey_id) do
    PasskeyCredential |> where([p], p.id == ^passkey_id and p.user_id == ^user_id) |> Repo.one()
  end

  @doc ~s|Delete a passkey|
  def delete_passkey(%User{} = user, passkey_id) do
    case get_user_passkey(user, passkey_id) do
      nil -> {:error, :not_found}
      credential -> Repo.delete(credential)
    end
  end

  @doc ~s|Rename a passkey|
  def rename_passkey(%User{} = user, passkey_id, new_name) do
    case get_user_passkey(user, passkey_id) do
      nil -> {:error, :not_found}
      credential -> credential |> PasskeyCredential.rename_changeset(new_name) |> Repo.update()
    end
  end

  defp get_credential_by_id(credential_id) do
    PasskeyCredential |> where([p], p.credential_id == ^credential_id) |> Repo.one()
  end

  defp list_credential_ids_for_user(%User{id: user_id}) do
    PasskeyCredential
    |> where([p], p.user_id == ^user_id)
    |> select([p], p.credential_id)
    |> Repo.all()
  end

  defp get_or_generate_user_handle(%User{id: user_id}) do
    existing =
      PasskeyCredential
      |> where([p], p.user_id == ^user_id)
      |> select([p], p.user_handle)
      |> limit(1)
      |> Repo.one()

    case existing do
      nil -> PasskeyCredential.generate_user_handle()
      handle -> handle
    end
  end

  defp generate_passkey_name(%User{} = user) do
    count = count_user_passkeys(user) + 1
    "Passkey #{count}"
  end

  @allowed_passkey_domains ["z.org", "elektrine.com", "localhost"]
  defp get_rp_id(nil) do
    Application.get_env(:elektrine, :passkey_rp_id, "localhost")
  end

  defp get_rp_id(host) when is_binary(host) do
    rp_id = extract_registrable_domain(host)

    if rp_id in @allowed_passkey_domains do
      rp_id
    else
      Application.get_env(:elektrine, :passkey_rp_id, "localhost")
    end
  end

  defp get_origin(nil) do
    Application.get_env(:elektrine, :passkey_origin, "http://localhost:4000")
  end

  defp get_origin(host) when is_binary(host) do
    rp_id = get_rp_id(host)

    if rp_id == "localhost" do
      "http://localhost:4000"
    else
      "https://#{rp_id}"
    end
  end

  defp extract_registrable_domain(host) do
    host
    |> String.downcase()
    |> String.split(".")
    |> case do
      [single] -> single
      [_, _] = parts -> Enum.join(parts, ".")
      parts when length(parts) >= 3 -> parts |> Enum.take(-2) |> Enum.join(".")
    end
  end

  defp decode_public_key(data) when is_binary(data) do
    {:ok, :erlang.binary_to_term(data, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid_binary}
  end

  defp decode_public_key(_) do
    {:error, :invalid_key}
  end

  defp decode_base64url(nil) do
    {:error, :missing_data}
  end

  defp decode_base64url(data) when is_binary(data) do
    case Base.url_decode64(data, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  defp decode_base64url(_) do
    {:error, :invalid_data}
  end
end
