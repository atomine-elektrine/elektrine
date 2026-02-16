defmodule Elektrine.CustomDomains.AcmeClient do
  @moduledoc """
  ACME client for Let's Encrypt certificate provisioning.

  Implements the ACME protocol (RFC 8555) for obtaining SSL certificates
  using HTTP-01 challenges.

  ## Flow

  1. Create/load account with Let's Encrypt
  2. Create order for domain
  3. Get HTTP-01 challenge
  4. Store challenge token/response in challenge store
  5. Notify Let's Encrypt to verify
  6. Finalize order with CSR
  7. Download certificate

  ## Usage

      {:ok, cert_pem, key_pem, expires_at} = AcmeClient.provision_certificate("example.com")
  """

  require Logger
  alias Elektrine.Telemetry.Events

  @le_production "https://acme-v02.api.letsencrypt.org/directory"
  @le_staging "https://acme-staging-v02.api.letsencrypt.org/directory"

  @finch_name Elektrine.Finch
  @http_timeout 30_000

  # Account key is generated once and stored on persistent volume
  @account_key_path "/data/certs/acme/account_key.pem"

  ## Public API

  @doc """
  Provisions a certificate for a domain.

  This is the main entry point. It handles the full ACME flow:
  1. Ensures account exists
  2. Creates order
  3. Handles HTTP-01 challenge
  4. Gets certificate

  Returns `{:ok, certificate_pem, private_key_pem, expires_at}` or `{:error, reason}`.
  """
  def provision_certificate(domain, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)

    if System.get_env("LETS_ENCRYPT_ENABLED") != "true" do
      Events.cert(:acme_client, :provision, :disabled, nil, %{domain: domain})
      {:error, :acme_disabled}
    else
      directory_url = Keyword.get(opts, :directory_url, get_directory_url())
      contact_email = Keyword.get(opts, :contact_email, get_contact_email())

      Logger.info("Starting certificate provisioning for #{domain}")

      with {:ok, directory} <- get_directory(directory_url),
           {:ok, account_key} <- get_or_create_account_key(),
           {:ok, account_url} <- get_or_create_account(directory, account_key, contact_email),
           {:ok, order_url, authorizations} <-
             create_order(directory, account_key, account_url, domain),
           {:ok, _} <- handle_challenges(authorizations, account_key, account_url, domain),
           {:ok, domain_key} <- generate_domain_key(),
           {:ok, csr} <- generate_csr(domain, domain_key),
           {:ok, cert_url} <- finalize_order(directory, account_key, account_url, order_url, csr),
           {:ok, certificate_pem, expires_at} <-
             download_certificate(cert_url, account_key, account_url) do
        domain_key_pem = export_private_key(domain_key)
        Logger.info("Certificate provisioned successfully for #{domain}, expires: #{expires_at}")

        Events.cert(
          :acme_client,
          :provision,
          :success,
          System.monotonic_time(:millisecond) - started_at,
          %{
            domain: domain,
            expires_at: DateTime.to_iso8601(expires_at)
          }
        )

        {:ok, certificate_pem, domain_key_pem, expires_at}
      else
        {:error, reason} = error ->
          Logger.error("Certificate provisioning failed for #{domain}: #{inspect(reason)}")

          Events.cert(
            :acme_client,
            :provision,
            :failure,
            System.monotonic_time(:millisecond) - started_at,
            %{
              domain: domain,
              stage: provision_stage(reason),
              reason: inspect(reason)
            }
          )

          error
      end
    end
  end

  @doc """
  Returns the directory URL (staging or production).
  """
  def get_directory_url do
    case Application.get_env(:elektrine, :acme_environment, :staging) do
      :production -> @le_production
      _ -> @le_staging
    end
  end

  ## Directory

  defp get_directory(url) do
    case http_get(url) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status}} ->
        {:error, {:directory_error, status}}

      {:error, reason} ->
        {:error, {:directory_error, reason}}
    end
  end

  ## Account Management

  defp get_or_create_account_key do
    key_path = get_account_key_path()

    if File.exists?(key_path) do
      case File.read(key_path) do
        {:ok, pem} ->
          [entry] = :public_key.pem_decode(pem)
          {:ok, :public_key.pem_entry_decode(entry)}

        {:error, reason} ->
          {:error, {:account_key_read_error, reason}}
      end
    else
      # Generate new account key
      key = :public_key.generate_key({:rsa, 2048, 65537})

      # Ensure directory exists
      File.mkdir_p!(Path.dirname(key_path))

      # Save key
      pem = export_private_key(key)
      File.write!(key_path, pem)

      {:ok, key}
    end
  end

  defp get_or_create_account(directory, account_key, contact_email) do
    new_account_url = directory["newAccount"]

    payload = %{
      "termsOfServiceAgreed" => true,
      "contact" => ["mailto:#{contact_email}"]
    }

    case acme_post(new_account_url, payload, account_key, nil, directory) do
      {:ok, %{status: status, headers: headers}} when status in [200, 201] ->
        account_url = get_header(headers, "location")
        {:ok, account_url}

      {:ok, %{status: status, body: body}} ->
        {:error, {:account_error, status, body}}

      {:error, reason} ->
        {:error, {:account_error, reason}}
    end
  end

  ## Order Management

  defp create_order(directory, account_key, account_url, domain) do
    new_order_url = directory["newOrder"]

    payload = %{
      "identifiers" => [
        %{"type" => "dns", "value" => domain}
      ]
    }

    case acme_post(new_order_url, payload, account_key, account_url, directory) do
      {:ok, %{status: 201, headers: headers, body: body}} ->
        order = Jason.decode!(body)
        order_url = get_header(headers, "location")
        {:ok, order_url, order["authorizations"]}

      {:ok, %{status: status, body: body}} ->
        {:error, {:order_error, status, body}}

      {:error, reason} ->
        {:error, {:order_error, reason}}
    end
  end

  ## Challenge Handling

  defp handle_challenges(authorization_urls, account_key, account_url, domain) do
    Enum.reduce_while(authorization_urls, {:ok, []}, fn auth_url, {:ok, acc} ->
      case handle_authorization(auth_url, account_key, account_url, domain) do
        :ok -> {:cont, {:ok, [:ok | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp handle_authorization(auth_url, account_key, account_url, domain) do
    # Get authorization details
    case acme_post_as_get(auth_url, account_key, account_url) do
      {:ok, %{status: 200, body: body}} ->
        auth = Jason.decode!(body)

        # Find HTTP-01 challenge
        challenge =
          Enum.find(auth["challenges"], fn c -> c["type"] == "http-01" end)

        if challenge do
          handle_http01_challenge(challenge, account_key, account_url, domain)
        else
          {:error, :no_http01_challenge}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:authorization_error, status, body}}

      {:error, reason} ->
        {:error, {:authorization_error, reason}}
    end
  end

  defp handle_http01_challenge(challenge, account_key, account_url, domain) do
    started_at = System.monotonic_time(:millisecond)
    token = challenge["token"]
    challenge_url = challenge["url"]

    # Compute key authorization
    key_authorization = compute_key_authorization(token, account_key)

    # Store challenge response for HTTP-01 verification.
    Elektrine.CustomDomains.AcmeChallengeStore.put(token, key_authorization)

    # Small delay to ensure storage is committed
    Process.sleep(1000)

    # Notify ACME server we're ready
    case acme_post(challenge_url, %{}, account_key, account_url, nil) do
      {:ok, %{status: status}} when status in [200, 202] ->
        # Poll for challenge completion
        case poll_challenge_status(challenge_url, account_key, account_url) do
          :ok ->
            Events.cert(
              :acme_client,
              :challenge,
              :success,
              System.monotonic_time(:millisecond) - started_at,
              %{domain: domain}
            )

            :ok

          {:error, reason} = error ->
            Events.cert(
              :acme_client,
              :challenge,
              :failure,
              System.monotonic_time(:millisecond) - started_at,
              %{domain: domain, reason: inspect(reason)}
            )

            error
        end

      {:ok, %{status: status, body: body}} ->
        Events.cert(
          :acme_client,
          :challenge,
          :failure,
          System.monotonic_time(:millisecond) - started_at,
          %{domain: domain, reason: inspect({:challenge_error, status, body})}
        )

        {:error, {:challenge_error, status, body}}

      {:error, reason} ->
        Events.cert(
          :acme_client,
          :challenge,
          :failure,
          System.monotonic_time(:millisecond) - started_at,
          %{domain: domain, reason: inspect({:challenge_error, reason})}
        )

        {:error, {:challenge_error, reason}}
    end
  end

  defp poll_challenge_status(challenge_url, account_key, account_url, attempts \\ 10) do
    if attempts <= 0 do
      {:error, :challenge_timeout}
    else
      Process.sleep(2000)

      case acme_post_as_get(challenge_url, account_key, account_url) do
        {:ok, %{status: 200, body: body}} ->
          challenge = Jason.decode!(body)

          case challenge["status"] do
            "valid" ->
              :ok

            "pending" ->
              poll_challenge_status(challenge_url, account_key, account_url, attempts - 1)

            "processing" ->
              poll_challenge_status(challenge_url, account_key, account_url, attempts - 1)

            "invalid" ->
              {:error, {:challenge_invalid, challenge["error"]}}

            status ->
              {:error, {:challenge_unexpected_status, status}}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:challenge_poll_error, status, body}}

        {:error, reason} ->
          {:error, {:challenge_poll_error, reason}}
      end
    end
  end

  ## Order Finalization

  defp finalize_order(directory, account_key, account_url, order_url, csr) do
    started_at = System.monotonic_time(:millisecond)

    # First get the order to find finalize URL
    result =
      case acme_post_as_get(order_url, account_key, account_url) do
        {:ok, %{status: 200, body: body}} ->
          order = Jason.decode!(body)
          finalize_url = order["finalize"]

          # Submit CSR
          csr_der = :public_key.der_encode(:CertificationRequest, csr)
          csr_b64 = Base.url_encode64(csr_der, padding: false)

          case acme_post(finalize_url, %{"csr" => csr_b64}, account_key, account_url, directory) do
            {:ok, %{status: 200, body: finalize_body}} ->
              finalize_order = Jason.decode!(finalize_body)

              case finalize_order["status"] do
                "valid" ->
                  {:ok, finalize_order["certificate"]}

                "processing" ->
                  # Poll for completion
                  poll_order_status(order_url, account_key, account_url)

                status ->
                  {:error, {:finalize_unexpected_status, status}}
              end

            {:ok, %{status: status, body: error_body}} ->
              {:error, {:finalize_error, status, error_body}}

            {:error, reason} ->
              {:error, {:finalize_error, reason}}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:order_fetch_error, status, body}}

        {:error, reason} ->
          {:error, {:order_fetch_error, reason}}
      end

    emit_stage_result(:finalize, result, started_at)
    result
  end

  defp poll_order_status(order_url, account_key, account_url, attempts \\ 10) do
    if attempts <= 0 do
      {:error, :order_timeout}
    else
      Process.sleep(2000)

      case acme_post_as_get(order_url, account_key, account_url) do
        {:ok, %{status: 200, body: body}} ->
          order = Jason.decode!(body)

          case order["status"] do
            "valid" ->
              {:ok, order["certificate"]}

            "processing" ->
              poll_order_status(order_url, account_key, account_url, attempts - 1)

            "invalid" ->
              {:error, {:order_invalid, order["error"]}}

            status ->
              {:error, {:order_unexpected_status, status}}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:order_poll_error, status, body}}

        {:error, reason} ->
          {:error, {:order_poll_error, reason}}
      end
    end
  end

  ## Certificate Download

  defp download_certificate(cert_url, account_key, account_url) do
    started_at = System.monotonic_time(:millisecond)

    result =
      case acme_post_as_get(
             cert_url,
             account_key,
             account_url,
             "application/pem-certificate-chain"
           ) do
        {:ok, %{status: 200, body: certificate_pem}} ->
          # Parse certificate to get expiry
          expires_at = extract_certificate_expiry(certificate_pem)
          {:ok, certificate_pem, expires_at}

        {:ok, %{status: status, body: body}} ->
          {:error, {:certificate_download_error, status, body}}

        {:error, reason} ->
          {:error, {:certificate_download_error, reason}}
      end

    emit_stage_result(:download, result, started_at)
    result
  end

  ## Crypto Helpers

  defp generate_domain_key do
    {:ok, :public_key.generate_key({:rsa, 2048, 65537})}
  end

  defp generate_csr(domain, private_key) do
    subject = {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, domain}}]]}

    public_key = extract_public_key(private_key)

    csr_info = {
      :CertificationRequestInfo,
      :v1,
      subject,
      public_key,
      :asn1_NOVALUE
    }

    # Sign CSR
    csr_der = :public_key.der_encode(:CertificationRequestInfo, csr_info)
    signature = :public_key.sign(csr_der, :sha256, private_key)

    csr = {
      :CertificationRequest,
      csr_info,
      {:AlgorithmIdentifier, {1, 2, 840, 113_549, 1, 1, 11}, <<5, 0>>},
      signature
    }

    {:ok, csr}
  end

  defp extract_public_key({:RSAPrivateKey, _, modulus, public_exp, _, _, _, _, _, _, _}) do
    {
      :SubjectPublicKeyInfo,
      {:AlgorithmIdentifier, {1, 2, 840, 113_549, 1, 1, 1}, <<5, 0>>},
      {:RSAPublicKey, modulus, public_exp}
    }
  end

  defp export_private_key(key) do
    entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
    :public_key.pem_encode([entry])
  end

  defp compute_key_authorization(token, account_key) do
    jwk_thumbprint = compute_jwk_thumbprint(account_key)
    "#{token}.#{jwk_thumbprint}"
  end

  defp compute_jwk_thumbprint(account_key) do
    jwk = account_key_to_jwk(account_key)

    # Canonical JSON (sorted keys, no whitespace)
    json = Jason.encode!(jwk, maps: :strict)

    :crypto.hash(:sha256, json)
    |> Base.url_encode64(padding: false)
  end

  defp account_key_to_jwk({:RSAPrivateKey, _, modulus, public_exp, _, _, _, _, _, _, _}) do
    %{
      "e" => int_to_b64(public_exp),
      "kty" => "RSA",
      "n" => int_to_b64(modulus)
    }
  end

  defp int_to_b64(int) do
    int
    |> :binary.encode_unsigned()
    |> Base.url_encode64(padding: false)
  end

  defp extract_certificate_expiry(cert_pem) do
    case :public_key.pem_decode(cert_pem) do
      [{:Certificate, cert_der, _} | _] ->
        {:Certificate, {:TBSCertificate, _, _, _, _, _, validity, _, _, _, _, _}, _, _} =
          :public_key.der_decode(:Certificate, cert_der)

        {:Validity, _, {:utcTime, not_after}} = validity

        # Parse UTCTime format (YYMMDDHHMMSSZ)
        parse_utc_time(to_string(not_after))

      _ ->
        # Default to 90 days if parsing fails
        DateTime.utc_now() |> DateTime.add(90 * 24 * 60 * 60)
    end
  rescue
    _ -> DateTime.utc_now() |> DateTime.add(90 * 24 * 60 * 60)
  end

  defp parse_utc_time(
         <<yy::binary-size(2), mm::binary-size(2), dd::binary-size(2), hh::binary-size(2),
           min::binary-size(2), ss::binary-size(2), "Z">>
       ) do
    year = String.to_integer(yy)
    year = if year >= 50, do: 1900 + year, else: 2000 + year

    {:ok, datetime} =
      NaiveDateTime.new(
        year,
        String.to_integer(mm),
        String.to_integer(dd),
        String.to_integer(hh),
        String.to_integer(min),
        String.to_integer(ss)
      )

    DateTime.from_naive!(datetime, "Etc/UTC")
  end

  ## ACME HTTP Helpers

  defp acme_post(url, payload, account_key, account_url, directory) do
    nonce = get_nonce(directory, url)
    protected = build_protected_header(url, nonce, account_key, account_url)
    jws = build_jws(protected, payload, account_key)

    http_post(url, Jason.encode!(jws), [{"content-type", "application/jose+json"}])
  end

  defp acme_post_as_get(url, account_key, account_url, accept \\ "application/json") do
    # POST-as-GET uses empty string payload
    nonce = get_nonce(nil, url)
    protected = build_protected_header(url, nonce, account_key, account_url)
    jws = build_jws(protected, "", account_key)

    http_post(url, Jason.encode!(jws), [
      {"content-type", "application/jose+json"},
      {"accept", accept}
    ])
  end

  defp get_nonce(directory, _url) when is_map(directory) do
    case http_head(directory["newNonce"]) do
      {:ok, %{headers: headers}} -> get_header(headers, "replay-nonce")
      _ -> nil
    end
  end

  defp get_nonce(nil, url) do
    # Extract base URL and get nonce from newNonce endpoint
    uri = URI.parse(url)
    directory_url = "#{uri.scheme}://#{uri.host}/directory"

    case get_directory(directory_url) do
      {:ok, directory} -> get_nonce(directory, url)
      _ -> nil
    end
  end

  defp build_protected_header(url, nonce, account_key, nil) do
    # For new account registration, include JWK
    %{
      "alg" => "RS256",
      "nonce" => nonce,
      "url" => url,
      "jwk" => account_key_to_jwk(account_key)
    }
  end

  defp build_protected_header(url, nonce, _account_key, account_url) do
    # For authenticated requests, use kid
    %{
      "alg" => "RS256",
      "nonce" => nonce,
      "url" => url,
      "kid" => account_url
    }
  end

  defp build_jws(protected, payload, account_key) do
    protected_b64 = protected |> Jason.encode!() |> Base.url_encode64(padding: false)

    payload_b64 =
      case payload do
        "" -> ""
        _ -> payload |> Jason.encode!() |> Base.url_encode64(padding: false)
      end

    signing_input = "#{protected_b64}.#{payload_b64}"
    signature = :public_key.sign(signing_input, :sha256, account_key)
    signature_b64 = Base.url_encode64(signature, padding: false)

    %{
      "protected" => protected_b64,
      "payload" => payload_b64,
      "signature" => signature_b64
    }
  end

  ## HTTP Helpers

  defp http_get(url) do
    request = Finch.build(:get, url)

    case Finch.request(request, @finch_name, receive_timeout: @http_timeout) do
      {:ok, %Finch.Response{status: status, headers: headers, body: body}} ->
        {:ok, %{status: status, headers: headers, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_head(url) do
    request = Finch.build(:head, url)

    case Finch.request(request, @finch_name, receive_timeout: @http_timeout) do
      {:ok, %Finch.Response{status: status, headers: headers}} ->
        {:ok, %{status: status, headers: headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_post(url, body, headers) do
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, @finch_name, receive_timeout: @http_timeout) do
      {:ok, %Finch.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, %{status: status, headers: resp_headers, body: resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_header(headers, name) do
    name_lower = String.downcase(name)

    case Enum.find(headers, fn {k, _v} -> String.downcase(k) == name_lower end) do
      {_, value} -> value
      nil -> nil
    end
  end

  ## Configuration Helpers

  defp get_account_key_path do
    Application.get_env(:elektrine, :acme_account_key_path, @account_key_path)
  end

  defp get_contact_email do
    Application.get_env(:elektrine, :acme_contact_email, "admin@elektrine.com")
  end

  defp emit_stage_result(stage, {:ok, _, _}, started_at) do
    Events.cert(
      :acme_client,
      stage,
      :success,
      System.monotonic_time(:millisecond) - started_at,
      %{}
    )
  end

  defp emit_stage_result(stage, {:ok, _}, started_at) do
    Events.cert(
      :acme_client,
      stage,
      :success,
      System.monotonic_time(:millisecond) - started_at,
      %{}
    )
  end

  defp emit_stage_result(stage, {:error, reason}, started_at) do
    Events.cert(
      :acme_client,
      stage,
      :failure,
      System.monotonic_time(:millisecond) - started_at,
      %{reason: inspect(reason)}
    )
  end

  defp provision_stage({:directory_error, _}), do: :directory
  defp provision_stage({:account_error, _}), do: :account
  defp provision_stage({:account_error, _, _}), do: :account
  defp provision_stage({:order_error, _}), do: :order
  defp provision_stage({:order_error, _, _}), do: :order
  defp provision_stage({:authorization_error, _}), do: :authorization
  defp provision_stage({:authorization_error, _, _}), do: :authorization
  defp provision_stage({:challenge_error, _}), do: :challenge
  defp provision_stage({:challenge_error, _, _}), do: :challenge
  defp provision_stage({:challenge_invalid, _}), do: :challenge
  defp provision_stage(:challenge_timeout), do: :challenge
  defp provision_stage({:order_fetch_error, _}), do: :finalize
  defp provision_stage({:order_fetch_error, _, _}), do: :finalize
  defp provision_stage({:finalize_error, _}), do: :finalize
  defp provision_stage({:finalize_error, _, _}), do: :finalize
  defp provision_stage({:certificate_download_error, _}), do: :download
  defp provision_stage({:certificate_download_error, _, _}), do: :download
  defp provision_stage(_), do: :unknown
end
