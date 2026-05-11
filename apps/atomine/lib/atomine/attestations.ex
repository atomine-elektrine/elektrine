defmodule Atomine.Attestations do
  @moduledoc """
  Portable anti-bot attestations.

  This module intentionally separates three low-friction signals from durable
  DNS/web identity claims:

  * proof-of-work receipts: signed proof that local compute was spent
  * passkey receipts: signed proof that an authenticated account has passkey continuity
  * anonymous effort tokens: MVP bearer tokens that can later be replaced by blind tokens
  """

  import Ecto.Query, warn: false

  alias Atomine.Attestation
  alias Elektrine.Accounts.PasskeyCredential
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  @pow_challenge_prefix "Atomine pow challenge v1"
  @receipt_prefix "Atomine receipt v1"
  @anonymous_token_prefix "Atomine anonymous effort token v1"
  @default_pow_difficulty 18
  @default_pow_ttl_seconds 300
  @default_receipt_ttl_seconds 7 * 24 * 60 * 60
  @default_token_ttl_seconds 24 * 60 * 60

  @doc "Returns public issuer metadata for external verifiers."
  def issuer_metadata(endpoint_base \\ nil) do
    endpoint_base = normalize_endpoint_base(endpoint_base)

    %{
      issuer: issuer(),
      protocol: "atomine-attestations",
      version: "v1",
      signing_alg: "hmac-sha256-dev",
      artifacts: ["pow_receipt", "anonymous_effort_token", "passkey_receipt"],
      privacy: %{
        anonymous_effort_token: "bearer-token-mvp",
        blind_tokens: "planned"
      },
      endpoints: %{
        pow_challenge: endpoint(endpoint_base, "/api/atomine/pow/challenge"),
        pow_receipts: endpoint(endpoint_base, "/api/atomine/pow/receipts"),
        anonymous_tokens: endpoint(endpoint_base, "/api/atomine/anonymous-tokens"),
        spend_anonymous_token: endpoint(endpoint_base, "/api/atomine/anonymous-tokens/spend"),
        verify_artifact: endpoint(endpoint_base, "/api/atomine/artifacts/verify")
      }
    }
  end

  @doc "Issues a stateless Atomine proof challenge."
  def issue_pow_challenge(opts \\ []) do
    now = now()
    difficulty = normalize_difficulty(Keyword.get(opts, :difficulty, @default_pow_difficulty))
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_pow_ttl_seconds)

    payload = %{
      "kind" => "pow_challenge",
      "issuer" => issuer(),
      "difficulty" => difficulty,
      "nonce" => random_token(18),
      "issued_at" => encode_time(now),
      "expires_at" => encode_time(DateTime.add(now, ttl_seconds, :second))
    }

    {:ok,
     %{
       challenge: sign_statement(@pow_challenge_prefix, payload),
       difficulty: difficulty,
       expires_at: payload["expires_at"]
     }}
  end

  @doc "Verifies a PoW solution and issues a portable signed receipt."
  def issue_pow_receipt(attrs) when is_map(attrs) do
    with {:ok, challenge_payload} <-
           parse_statement(Map.get(attrs, "challenge"), @pow_challenge_prefix),
         :ok <- ensure_not_expired(challenge_payload),
         solution when is_binary(solution) and solution != "" <- Map.get(attrs, "solution"),
         true <-
           valid_pow_solution?(
             Map.get(attrs, "challenge"),
             solution,
             challenge_payload["difficulty"]
           ) do
      subject = Map.get(attrs, "subject")

      issue_receipt(
        "pow_receipt",
        subject,
        challenge_payload["difficulty"],
        %{
          "challenge_hash" => artifact_hash(Map.get(attrs, "challenge")),
          "solution_hash" => artifact_hash(solution)
        },
        user_id: Map.get(attrs, :user_id)
      )
    else
      false -> {:error, :invalid_pow_solution}
      nil -> {:error, :missing_pow_solution}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_pow_solution}
    end
  end

  @doc "Issues a bearer anonymous effort token after a valid PoW solution."
  def issue_anonymous_effort_token(attrs) when is_map(attrs) do
    with {:ok, challenge_payload} <-
           parse_statement(Map.get(attrs, "challenge"), @pow_challenge_prefix),
         :ok <- ensure_not_expired(challenge_payload),
         solution when is_binary(solution) and solution != "" <- Map.get(attrs, "solution"),
         true <-
           valid_pow_solution?(
             Map.get(attrs, "challenge"),
             solution,
             challenge_payload["difficulty"]
           ) do
      now = now()
      public_id = public_id("aet")

      payload = %{
        "id" => public_id,
        "kind" => "anonymous_effort_token",
        "issuer" => issuer(),
        "difficulty" => challenge_payload["difficulty"],
        "issued_at" => encode_time(now),
        "expires_at" => encode_time(DateTime.add(now, @default_token_ttl_seconds, :second)),
        "nonce" => random_token(24)
      }

      token = sign_statement(@anonymous_token_prefix, payload)

      insert_attestation(%{
        public_id: public_id,
        kind: "anonymous_effort_token",
        status: "issued",
        issuer: issuer(),
        artifact: token,
        artifact_hash: artifact_hash(token),
        difficulty: challenge_payload["difficulty"],
        issued_at: now,
        expires_at: decode_time!(payload["expires_at"]),
        metadata: %{"challenge_hash" => artifact_hash(Map.get(attrs, "challenge"))}
      })
    else
      false -> {:error, :invalid_pow_solution}
      nil -> {:error, :missing_pow_solution}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_pow_solution}
    end
  end

  @doc "Redeems an anonymous effort token once."
  def redeem_anonymous_effort_token(token, attrs \\ %{})

  def redeem_anonymous_effort_token(token, attrs) when is_binary(token) and is_map(attrs) do
    with {:ok, payload} <- parse_statement(token, @anonymous_token_prefix),
         :ok <- ensure_not_expired(payload),
         :ok <- validate_token_spend_attrs(attrs),
         %Attestation{} = attestation <-
           Repo.get_by(Attestation, artifact_hash: artifact_hash(token)) do
      cond do
        attestation.status == "redeemed" ->
          {:error, :already_redeemed}

        DateTime.compare(attestation.expires_at, now()) == :lt ->
          update_status(attestation, "expired")
          {:error, :expired}

        true ->
          attestation
          |> Attestation.changeset(%{
            status: "redeemed",
            redeemed_at: now(),
            metadata: spend_metadata(attestation.metadata, attrs, payload)
          })
          |> Repo.update()
      end
    else
      nil -> {:error, :unknown_token}
      {:error, reason} -> {:error, reason}
    end
  end

  def redeem_anonymous_effort_token(_, _), do: {:error, :invalid_token}

  @doc "Issues a passkey-bound continuity receipt for an authenticated user."
  def issue_passkey_receipt(%User{id: user_id}, passkey_credential_id) do
    with {id, ""} <- Integer.parse(to_string(passkey_credential_id)),
         %PasskeyCredential{user_id: ^user_id} = credential <- Repo.get(PasskeyCredential, id) do
      subject = "passkey:#{credential_fingerprint(credential)}"

      issue_receipt(
        "passkey_receipt",
        subject,
        nil,
        %{
          "passkey_credential_id" => credential.id,
          "passkey_name" => credential.name,
          "passkey_fingerprint" => credential_fingerprint(credential)
        },
        user_id: user_id,
        passkey_credential_id: credential.id
      )
    else
      nil -> {:error, :passkey_not_found}
      :error -> {:error, :invalid_passkey_id}
      _ -> {:error, :passkey_not_found}
    end
  end

  def issue_passkey_receipt(_, _), do: {:error, :invalid_user}

  @doc "Verifies any Atomine receipt/token statement signature and expiry."
  def verify_artifact(artifact) when is_binary(artifact) do
    cond do
      String.starts_with?(artifact, @receipt_prefix) ->
        verify_signed_artifact(artifact, @receipt_prefix)

      String.starts_with?(artifact, @anonymous_token_prefix) ->
        verify_signed_artifact(artifact, @anonymous_token_prefix)

      true ->
        {:error, :unsupported_artifact}
    end
  end

  def verify_artifact(_), do: {:error, :invalid_artifact}

  defp verify_signed_artifact(artifact, prefix) do
    with {:ok, payload} <- parse_statement(artifact, prefix),
         :ok <- ensure_not_expired(payload) do
      persisted = Repo.get_by(Attestation, artifact_hash: artifact_hash(artifact))

      {:ok,
       %{
         payload: payload,
         persisted: !is_nil(persisted),
         status: persisted && persisted.status
       }}
    end
  end

  defp issue_receipt(kind, subject, difficulty, metadata, opts) do
    now = now()
    public_id = public_id("rcpt")
    expires_at = DateTime.add(now, @default_receipt_ttl_seconds, :second)

    payload = %{
      "id" => public_id,
      "kind" => kind,
      "issuer" => issuer(),
      "subject_hash" => subject_hash(subject),
      "difficulty" => difficulty,
      "issued_at" => encode_time(now),
      "expires_at" => encode_time(expires_at),
      "nonce" => random_token(24)
    }

    receipt = sign_statement(@receipt_prefix, payload)

    insert_attestation(%{
      public_id: public_id,
      user_id: Keyword.get(opts, :user_id),
      passkey_credential_id: Keyword.get(opts, :passkey_credential_id),
      kind: kind,
      status: "issued",
      issuer: issuer(),
      subject: subject,
      subject_hash: subject_hash(subject),
      artifact: receipt,
      artifact_hash: artifact_hash(receipt),
      difficulty: difficulty,
      issued_at: now,
      expires_at: expires_at,
      metadata: metadata
    })
  end

  defp insert_attestation(attrs) do
    %Attestation{}
    |> Attestation.changeset(attrs)
    |> Repo.insert()
  end

  defp update_status(attestation, status) do
    attestation
    |> Attestation.changeset(%{status: status})
    |> Repo.update()
  end

  defp validate_token_spend_attrs(attrs) do
    audience = Map.get(attrs, "audience")
    nonce = Map.get(attrs, "nonce")

    cond do
      not is_nil(audience) and not valid_spend_field?(audience, 500) ->
        {:error, :invalid_audience}

      not is_nil(nonce) and not valid_spend_field?(nonce, 200) ->
        {:error, :invalid_nonce}

      true ->
        :ok
    end
  end

  defp valid_spend_field?(value, max_length) when is_binary(value) do
    value = String.trim(value)
    value != "" and String.length(value) <= max_length
  end

  defp valid_spend_field?(_value, _max_length), do: false

  defp spend_metadata(metadata, attrs, payload) do
    spend =
      %{
        "token_id" => payload["id"],
        "spent_at" => encode_time(now())
      }
      |> maybe_put_trimmed("audience", Map.get(attrs, "audience"))
      |> maybe_put_trimmed("nonce", Map.get(attrs, "nonce"))

    metadata
    |> ensure_map()
    |> Map.put("spend", spend)
  end

  defp maybe_put_trimmed(map, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> map
      trimmed -> Map.put(map, key, trimmed)
    end
  end

  defp maybe_put_trimmed(map, _key, _value), do: map

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}

  defp valid_pow_solution?(challenge, solution, difficulty) do
    bits = normalize_difficulty(difficulty)

    digest = :crypto.hash(:sha256, challenge <> ":" <> solution)
    leading_zero_bits(digest) >= bits
  end

  defp leading_zero_bits(binary), do: leading_zero_bits(binary, 0)

  defp leading_zero_bits(<<0, rest::binary>>, acc), do: leading_zero_bits(rest, acc + 8)

  defp leading_zero_bits(<<byte, _rest::binary>>, acc) do
    acc + leading_zero_bits_in_byte(byte)
  end

  defp leading_zero_bits(<<>>, acc), do: acc

  defp leading_zero_bits_in_byte(byte) do
    Enum.find_value(7..0//-1, 8, fn shift ->
      if Bitwise.band(byte, Bitwise.bsl(1, shift)) != 0, do: 7 - shift
    end)
  end

  defp sign_statement(prefix, payload) do
    encoded_payload = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    signature = sign(encoded_payload)
    prefix <> " payload=" <> encoded_payload <> " sig=" <> signature
  end

  defp parse_statement(statement, prefix) when is_binary(statement) do
    with true <- String.starts_with?(statement, prefix <> " "),
         %{"payload" => encoded_payload, "sig" => signature} <- parse_fields(statement, prefix),
         true <- secure_compare(sign(encoded_payload), signature),
         {:ok, json} <- Base.url_decode64(encoded_payload, padding: false),
         {:ok, payload} <- Jason.decode(json) do
      {:ok, payload}
    else
      false -> {:error, :invalid_signature}
      :error -> {:error, :invalid_payload}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_statement}
    end
  end

  defp parse_statement(_, _), do: {:error, :invalid_statement}

  defp parse_fields(statement, prefix) do
    statement
    |> String.replace_prefix(prefix <> " ", "")
    |> String.split(" ", trim: true)
    |> Map.new(fn field ->
      case String.split(field, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
  end

  defp ensure_not_expired(%{"expires_at" => expires_at}) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, expires_at, _} ->
        if DateTime.compare(expires_at, now()) == :lt, do: {:error, :expired}, else: :ok

      _ ->
        {:error, :invalid_expiry}
    end
  end

  defp ensure_not_expired(_), do: {:error, :missing_expiry}

  defp decode_time!(value) do
    {:ok, time, _} = DateTime.from_iso8601(value)
    time
  end

  defp encode_time(%DateTime{} = time), do: DateTime.to_iso8601(time)

  defp normalize_difficulty(value) when is_integer(value), do: value |> max(0) |> min(64)

  defp normalize_difficulty(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> normalize_difficulty(parsed)
      :error -> @default_pow_difficulty
    end
  end

  defp normalize_difficulty(_), do: @default_pow_difficulty

  defp normalize_endpoint_base(nil), do: nil

  defp normalize_endpoint_base(""), do: nil
  defp normalize_endpoint_base(value) when is_binary(value), do: String.trim_trailing(value, "/")
  defp normalize_endpoint_base(_), do: nil

  defp endpoint(nil, path), do: path
  defp endpoint(base, path), do: base <> path

  defp public_id(prefix), do: prefix <> "_" <> random_token(18)

  defp random_token(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp subject_hash(nil), do: nil
  defp subject_hash(""), do: nil
  defp subject_hash(subject), do: artifact_hash("subject:" <> to_string(subject))

  defp artifact_hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.url_encode64(padding: false)
  end

  defp credential_fingerprint(%PasskeyCredential{credential_id: credential_id}) do
    credential_id
    |> Base.url_encode64(padding: false)
    |> artifact_hash()
  end

  defp sign(payload),
    do:
      :crypto.mac(:hmac, :sha256, signing_secret(), payload) |> Base.url_encode64(padding: false)

  defp signing_secret do
    System.get_env("ATOMINE_ATTESTATION_SECRET") || Elektrine.RuntimeSecrets.secret_key_base() ||
      "atomine-dev-attestation-secret"
  end

  defp issuer do
    System.get_env("ATOMINE_ISSUER") || Elektrine.ActivityPub.instance_url() || "atomine.local"
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_, _), do: false

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
