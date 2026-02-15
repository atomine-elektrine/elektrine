defmodule Elektrine.Accounts.Passkeys do
  @moduledoc """
  Context module for WebAuthn/Passkey management.

  Provides functions for:
  - Registering new passkeys
  - Authenticating with passkeys
  - Managing user's passkeys (list, rename, delete)
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.Accounts.{PasskeyCredential, User}
  alias Elektrine.AppCache
  require Logger

  # Challenge timeout in milliseconds (5 minutes)
  @challenge_timeout 300_000

  @doc """
  Generate a registration challenge for adding a new passkey.

  Returns {:ok, challenge_data} or {:error, reason}

  The challenge_data contains all information needed by the browser's
  WebAuthn API to create a new credential.

  Options:
    - :host - The request host (e.g., "z.org" or "elektrine.com") for multi-domain support
  """
  def generate_registration_challenge(user, opts \\ []) do
    passkey_count = count_user_passkeys(user)

    if passkey_count >= PasskeyCredential.max_passkeys_per_user() do
      {:error, :passkey_limit_reached}
    else
      # Get or generate user handle for this user
      user_handle = get_or_generate_user_handle(user)

      # Get existing credential IDs to exclude (prevent re-registration)
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

      # Wax.new_registration_challenge returns the challenge struct directly
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
         authenticator_selection: %{
           resident_key: "preferred",
           user_verification: "preferred"
         },
         exclude_credentials:
           Enum.map(exclude_credentials, fn cred_id ->
             %{type: "public-key", id: Base.url_encode64(cred_id, padding: false)}
           end),
         pub_key_cred_params: [
           %{type: "public-key", alg: -7},
           %{type: "public-key", alg: -257}
         ]
       }}
    end
  end

  @doc """
  Complete passkey registration by verifying the attestation.

  The attestation_response is expected to be a map with the following structure:
  - "response" => %{
      "clientDataJSON" => base64url encoded JSON string
      "attestationObject" => base64url encoded CBOR binary
      "transports" => optional list of transports
    }

  Returns {:ok, credential} or {:error, reason}
  """
  def complete_registration(user, challenge, attestation_response, metadata \\ %{}) do
    # Extract and decode the raw values from the response
    response = attestation_response["response"] || %{}

    with {:ok, client_data_json_raw} <- decode_base64url(response["clientDataJSON"]),
         {:ok, attestation_object_cbor} <- decode_base64url(response["attestationObject"]),
         {:ok, {authenticator_data, _attestation_result}} <-
           Wax.register(attestation_object_cbor, client_data_json_raw, challenge) do
      # Extract credential data
      credential_id = authenticator_data.attested_credential_data.credential_id
      public_key = authenticator_data.attested_credential_data.credential_public_key
      sign_count = authenticator_data.sign_count
      aaguid = authenticator_data.attested_credential_data.aaguid

      # Get user handle - same one used in registration challenge
      user_handle = get_or_generate_user_handle(user)

      # Extract transports from response if available (browser provides this)
      transports = response["transports"] || []

      # Create credential record
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

      %PasskeyCredential{}
      |> PasskeyCredential.create_changeset(attrs)
      |> Repo.insert()
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generate an authentication challenge for passkey login.

  For discoverable credentials (passkey login without username):
  - Pass nil for user
  - Browser will prompt user to select a passkey

  For non-discoverable credentials (after username entry):
  - Pass the user struct
  - Challenge will include allowed credentials for that user

  Options:
    - :host - The request host (e.g., "z.org" or "elektrine.com") for multi-domain support
  """
  def generate_authentication_challenge(user \\ nil, opts \\ []) do
    rp_id = get_rp_id(opts[:host])
    origin = get_origin(opts[:host])

    allowed_credentials =
      case user do
        nil ->
          # Discoverable credential flow - no allow list
          []

        %User{} = user ->
          # Get credentials for this specific user
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

    # Wax.new_authentication_challenge returns the challenge struct directly
    challenge = Wax.new_authentication_challenge(challenge_opts)

    # For the client, we need to format the credentials differently
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

    # Store the challenge in cache for later retrieval
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

  @doc """
  Retrieve a stored challenge from cache.
  Used by the controller to get the full challenge struct for verification.
  """
  def get_challenge(challenge_bytes) when is_binary(challenge_bytes) do
    AppCache.get_passkey_challenge(challenge_bytes)
  end

  @doc """
  Verify passkey authentication assertion.

  The assertion_response is expected to be a map with:
  - "id" or "rawId" => base64url encoded credential ID
  - "response" => %{
      "clientDataJSON" => base64url encoded JSON string
      "authenticatorData" => base64url encoded binary
      "signature" => base64url encoded binary
    }

  Returns {:ok, user} or {:error, reason}
  """
  def verify_authentication(challenge, assertion_response) do
    # Extract and decode credential ID
    credential_id_b64 = assertion_response["id"] || assertion_response["rawId"]
    response = assertion_response["response"] || %{}

    with {:ok, credential_id} <- decode_base64url(credential_id_b64),
         {:ok, client_data_json_raw} <- decode_base64url(response["clientDataJSON"]),
         {:ok, authenticator_data_bin} <- decode_base64url(response["authenticatorData"]),
         {:ok, signature} <- decode_base64url(response["signature"]) do
      # Find the credential
      case get_credential_by_id(credential_id) do
        nil ->
          {:error, :credential_not_found}

        credential ->
          case decode_public_key(credential.public_key) do
            {:ok, public_key} ->
              # Build credentials list for Wax
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

                  # Clone detection: sign count should always increase
                  # A sign count that doesn't increase indicates a potentially cloned authenticator
                  if new_sign_count > 0 and new_sign_count <= credential.sign_count do
                    Logger.warning(
                      "Passkey clone detection: credential #{inspect(credential.id)} " <>
                        "sign_count did not increase (stored: #{credential.sign_count}, received: #{new_sign_count})"
                    )

                    # Block authentication for security
                    {:error, :cloned_authenticator}
                  else
                    # Update sign count and last used
                    credential
                    |> PasskeyCredential.update_sign_count_changeset(new_sign_count)
                    |> Repo.update()

                    # Get the user
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

  @doc "List all passkeys for a user"
  def list_user_passkeys(%User{id: user_id}) do
    PasskeyCredential
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at)
    |> Repo.all()
  end

  @doc "Count passkeys for a user"
  def count_user_passkeys(%User{id: user_id}) do
    PasskeyCredential
    |> where([p], p.user_id == ^user_id)
    |> Repo.aggregate(:count, :id)
  end

  @doc "Check if user has any passkeys registered"
  def has_passkeys?(%User{} = user) do
    count_user_passkeys(user) > 0
  end

  @doc "Get a specific passkey by ID, scoped to user"
  def get_user_passkey(%User{id: user_id}, passkey_id) do
    PasskeyCredential
    |> where([p], p.id == ^passkey_id and p.user_id == ^user_id)
    |> Repo.one()
  end

  @doc "Delete a passkey"
  def delete_passkey(%User{} = user, passkey_id) do
    case get_user_passkey(user, passkey_id) do
      nil ->
        {:error, :not_found}

      credential ->
        Repo.delete(credential)
    end
  end

  @doc "Rename a passkey"
  def rename_passkey(%User{} = user, passkey_id, new_name) do
    case get_user_passkey(user, passkey_id) do
      nil ->
        {:error, :not_found}

      credential ->
        credential
        |> PasskeyCredential.rename_changeset(new_name)
        |> Repo.update()
    end
  end

  # Private helpers

  defp get_credential_by_id(credential_id) do
    PasskeyCredential
    |> where([p], p.credential_id == ^credential_id)
    |> Repo.one()
  end

  defp list_credential_ids_for_user(%User{id: user_id}) do
    PasskeyCredential
    |> where([p], p.user_id == ^user_id)
    |> select([p], p.credential_id)
    |> Repo.all()
  end

  defp get_or_generate_user_handle(%User{id: user_id}) do
    # Check if user already has a passkey with a user_handle
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

  # Allowed domains for passkey registration/authentication
  @allowed_passkey_domains ["z.org", "elektrine.com", "localhost"]

  defp get_rp_id(nil) do
    # Fall back to config if no host provided
    Application.get_env(:elektrine, :passkey_rp_id, "localhost")
  end

  defp get_rp_id(host) when is_binary(host) do
    # Extract the registrable domain from the host
    # e.g., "www.z.org" -> "z.org", "elektrine.com" -> "elektrine.com"
    rp_id = extract_registrable_domain(host)

    # Validate the domain is allowed
    if rp_id in @allowed_passkey_domains do
      rp_id
    else
      # Fall back to config for unknown domains
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

  # Extract the registrable domain (eTLD+1) from a hostname
  # Simple implementation that handles common cases
  defp extract_registrable_domain(host) do
    host
    |> String.downcase()
    |> String.split(".")
    |> case do
      # Single part (localhost)
      [single] ->
        single

      # Two parts (z.org, elektrine.com)
      [_, _] = parts ->
        Enum.join(parts, ".")

      # Three or more parts (www.z.org, sub.elektrine.com)
      parts when length(parts) >= 3 ->
        # Take last two parts as the registrable domain
        parts |> Enum.take(-2) |> Enum.join(".")
    end
  end

  # Helper to decode base64url-encoded data
  defp decode_public_key(data) when is_binary(data) do
    try do
      {:ok, :erlang.binary_to_term(data, [:safe])}
    rescue
      ArgumentError ->
        {:error, :invalid_binary}
    end
  end

  defp decode_public_key(_), do: {:error, :invalid_key}

  defp decode_base64url(nil), do: {:error, :missing_data}

  defp decode_base64url(data) when is_binary(data) do
    case Base.url_decode64(data, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  defp decode_base64url(_), do: {:error, :invalid_data}
end
