defmodule Atomine.Personhood do
  @moduledoc """
  Proof-of-personhood and anti-bot scoring context.

  This app owns personhood proof lifecycle and scoring. Other apps can consume
  `personhood_score/1` or `sufficiently_human?/2` when deciding whether to raise
  limits, allow sensitive actions, or reduce anti-bot friction.
  """

  import Ecto.Query, warn: false

  alias Atomine.Proof
  alias Atomine.Scoring
  alias Atomine.TrustSession
  alias Elektrine.Accounts.ConnectedAccount
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  @live_check_interval_days 30
  @live_stale_after_days 45
  @proof_statement_version "v1"

  @proof_weights %{
    "web" => 20,
    "dns" => 25,
    "social" => 15,
    "vouch" => 30,
    "payment" => 25,
    "passkey" => 20,
    "manual" => 100
  }

  @doc "Returns default score weights by proof kind."
  def proof_weights, do: @proof_weights

  @doc "Lists trust sessions newest first. Pass `:user_id`, `:merchant_id`, or `:status` to filter."
  def list_trust_sessions(opts \\ []) do
    TrustSession
    |> maybe_filter(:user_id, Keyword.get(opts, :user_id))
    |> maybe_filter(:merchant_id, Keyword.get(opts, :merchant_id))
    |> maybe_filter(:status, Keyword.get(opts, :status))
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  @doc "Gets a trust session by its public session id."
  def get_trust_session(public_id) when is_binary(public_id) do
    Repo.get_by(TrustSession, public_id: public_id)
  end

  def get_trust_session(_), do: nil

  @doc "Creates a guest trust session for checkout/signup/external flows."
  def create_trust_session(attrs) when is_map(attrs) do
    attrs
    |> stringify_keys()
    |> put_default_session_fields(nil)
    |> insert_trust_session()
  end

  @doc "Creates a trust session attached to a known Elektrine user."
  def create_trust_session(%User{} = user, attrs) when is_map(attrs) do
    attrs
    |> stringify_keys()
    |> put_default_session_fields(user)
    |> insert_trust_session()
  end

  @doc "Updates a trust session with a fresh decision or step-up state."
  def update_trust_session(%TrustSession{} = session, attrs) when is_map(attrs) do
    session
    |> TrustSession.changeset(stringify_keys(attrs))
    |> Repo.update()
  end

  @doc "Marks a trust session completed and records the final decision."
  def complete_trust_session(%TrustSession{} = session, attrs \\ %{}) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("status", "completed")
      |> Map.put_new("completed_at", now())

    update_trust_session(session, attrs)
  end

  @doc "Lists a user's proofs newest first."
  def list_proofs(user_id) when is_integer(user_id) do
    Proof
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at)
    |> Repo.all()
  end

  def list_proofs(_), do: []

  @doc "Lists proofs needing human/admin review."
  def list_pending_proofs do
    Proof
    |> where([p], p.status == "pending")
    |> order_by([p], asc: p.inserted_at)
    |> Repo.all()
  end

  @doc "Lists live proofs whose scheduled recheck is due."
  def list_due_live_proofs(limit \\ 100) do
    now = now()

    Proof
    |> where(
      [p],
      p.claim_type == "positive" and p.proof_mode == "live" and p.status == "verified" and
        not is_nil(p.next_check_at) and p.next_check_at <= ^now
    )
    |> order_by([p], asc: p.next_check_at)
    |> limit(^normalize_limit(limit))
    |> Repo.all()
  end

  @doc "Rechecks due live proofs and returns per-proof results."
  def recheck_due_live_proofs(limit \\ 100) do
    limit
    |> list_due_live_proofs()
    |> Enum.map(fn proof -> {proof, check_proof(proof)} end)
  end

  def get_proof!(id), do: Repo.get!(Proof, id)

  @doc "Creates a pending proof with a public challenge string."
  def create_proof(%User{} = user, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    kind = attrs |> Map.get("kind", "") |> normalize_kind()

    proof_mode = attrs |> Map.get("proof_mode", "snapshot") |> normalize_proof_mode()
    subject = Map.get(attrs, "subject")
    default_method = default_method_for_kind(kind, subject)

    verification_method =
      attrs |> Map.get("verification_method", default_method) |> normalize_method()

    challenge = Map.get(attrs, "challenge") || generate_challenge(user, kind, subject)

    %Proof{}
    |> Proof.changeset(%{
      user_id: user.id,
      kind: kind,
      claim_type: "positive",
      proof_mode: proof_mode,
      live_status: initial_live_status(proof_mode),
      verification_method: verification_method,
      subject: subject,
      status: "pending",
      challenge: challenge,
      evidence_url: Map.get(attrs, "evidence_url"),
      score_weight: Map.get(attrs, "score_weight") || Map.get(@proof_weights, kind, 0),
      metadata: proof_metadata(Map.get(attrs, "metadata"), verification_method, challenge)
    })
    |> Repo.insert()
  end

  @doc "Creates a hosted negative assertion, such as `I am not on Twitter`."
  def create_negative_assertion(%User{} = user, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    kind = attrs |> Map.get("kind", "social") |> normalize_kind()

    challenge =
      Map.get(attrs, "challenge") || generate_challenge(user, kind, Map.get(attrs, "subject"))

    %Proof{}
    |> Proof.changeset(%{
      user_id: user.id,
      kind: kind,
      claim_type: "negative",
      proof_mode: "snapshot",
      live_status: nil,
      verification_method: "none",
      subject: Map.get(attrs, "subject"),
      status: "asserted",
      challenge: challenge,
      evidence_url: Map.get(attrs, "evidence_url"),
      score_weight: 0,
      metadata: proof_metadata(Map.get(attrs, "metadata"), "none", challenge)
    })
    |> Repo.insert()
  end

  @doc "Creates or refreshes a verified proof from a connected OAuth/OIDC account."
  def verify_connected_account_proof(%ConnectedAccount{} = connected_account) do
    subject = connected_account_subject(connected_account)

    attrs = %{
      user_id: connected_account.user_id,
      kind: "social",
      claim_type: "positive",
      proof_mode: "live",
      live_status: "active",
      verification_method: "oauth",
      subject: subject,
      status: "verified",
      challenge: "OAuth account verified for #{subject}",
      evidence_url: connected_account.profile_url,
      score_weight: Map.get(@proof_weights, "social", 15),
      checked_at: now(),
      last_seen_at: now(),
      next_check_at: DateTime.add(now(), @live_check_interval_days, :day),
      stale_at: DateTime.add(now(), @live_stale_after_days, :day),
      verified_at: now(),
      metadata: %{
        "provider" => connected_account.provider,
        "provider_account_id" => connected_account.provider_account_id,
        "username" => connected_account.username,
        "display_name" => connected_account.display_name,
        "connected_account_id" => connected_account.id
      }
    }

    case Repo.get_by(Proof,
           user_id: connected_account.user_id,
           kind: "social",
           subject: subject,
           status: "verified"
         ) do
      %Proof{} = proof ->
        proof
        |> Proof.changeset(attrs)
        |> Repo.update()

      nil ->
        %Proof{}
        |> Proof.changeset(attrs)
        |> Repo.insert()
    end
  end

  @doc "Marks a proof verified and makes its weight count toward personhood score."
  def verify_proof(%Proof{} = proof, reviewer \\ nil, notes \\ nil) do
    now = now()

    proof
    |> Proof.changeset(%{
      status: "verified",
      checked_at: now,
      last_seen_at: live_timestamp(proof, now),
      next_check_at: next_check_at(proof, now),
      stale_at: stale_at(proof, now),
      live_status: verified_live_status(proof),
      failed_check_count: 0,
      verified_at: now,
      rejected_at: nil,
      revoked_at: nil,
      reviewed_by_user_id: reviewer_id(reviewer),
      review_notes: notes
    })
    |> Repo.update()
  end

  @doc "Rejects a pending proof without contributing score."
  def reject_proof(%Proof{} = proof, reviewer \\ nil, notes \\ nil) do
    proof
    |> Proof.changeset(%{
      status: "rejected",
      checked_at: now(),
      live_status: rejected_live_status(proof),
      rejected_at: now(),
      verified_at: nil,
      revoked_at: nil,
      reviewed_by_user_id: reviewer_id(reviewer),
      review_notes: notes
    })
    |> Repo.update()
  end

  @doc "Revokes a previously accepted proof."
  def revoke_proof(%Proof{} = proof, reviewer \\ nil, notes \\ nil) do
    proof
    |> Proof.changeset(%{
      status: "revoked",
      live_status: revoked_live_status(proof),
      revoked_at: now(),
      verified_at: nil,
      rejected_at: nil,
      reviewed_by_user_id: reviewer_id(reviewer),
      review_notes: notes
    })
    |> Repo.update()
  end

  @doc "Deletes a proof owned by a user."
  def delete_proof(%Proof{} = proof) do
    Repo.delete(proof)
  end

  @doc "Marks a live proof stale after an overdue or failed recheck."
  def mark_live_stale(proof, notes \\ nil)

  def mark_live_stale(%Proof{proof_mode: "live"} = proof, notes) do
    proof
    |> Proof.changeset(%{
      live_status: "stale",
      failed_check_count: proof.failed_check_count + 1,
      checked_at: now(),
      review_notes: notes || proof.review_notes
    })
    |> Repo.update()
  end

  def mark_live_stale(%Proof{} = proof, _notes), do: {:ok, proof}

  @doc "Marks a live proof inactive when its snippet can no longer be found."
  def mark_live_inactive(proof, notes \\ nil)

  def mark_live_inactive(%Proof{proof_mode: "live"} = proof, notes) do
    proof
    |> Proof.changeset(%{
      live_status: "inactive",
      failed_check_count: proof.failed_check_count + 1,
      checked_at: now(),
      review_notes: notes || proof.review_notes
    })
    |> Repo.update()
  end

  def mark_live_inactive(%Proof{} = proof, _notes), do: {:ok, proof}

  @doc "Checks a DNS or public page proof and verifies it when the challenge is published."
  def check_proof(%Proof{claim_type: "negative"}), do: {:error, :not_checkable}

  def check_proof(%Proof{status: status}) when status in ["rejected", "revoked"],
    do: {:error, :closed}

  def check_proof(%Proof{verification_method: "dns"} = proof) do
    case dns_challenge_present?(proof) do
      true -> verify_proof(proof, nil, "DNS TXT record matched")
      false -> mark_check_failed(proof, "DNS TXT record did not contain the challenge")
      {:error, reason} -> mark_check_failed(proof, "DNS check failed: #{inspect(reason)}")
    end
  end

  def check_proof(%Proof{verification_method: "page"} = proof) do
    case web_challenge_present?(proof) do
      true -> verify_proof(proof, nil, "Web page contained challenge")
      false -> mark_check_failed(proof, "Web page did not contain the challenge")
      {:error, reason} -> mark_check_failed(proof, "Web check failed: #{inspect(reason)}")
    end
  end

  def check_proof(%Proof{verification_method: "github_gist"} = proof) do
    case github_gist_challenge_present?(proof) do
      true -> verify_proof(proof, nil, "GitHub gist contained challenge")
      false -> mark_check_failed(proof, "GitHub gist did not contain the challenge")
      {:error, reason} -> mark_check_failed(proof, "GitHub gist check failed: #{inspect(reason)}")
    end
  end

  def check_proof(%Proof{}), do: {:error, :manual_review_required}

  @doc "Returns a detailed composite personhood score breakdown."
  def personhood_breakdown(user_or_id), do: Scoring.breakdown(user_or_id)

  @doc "Returns the capped composite personhood score for a user."
  def personhood_score(user_or_id), do: personhood_breakdown(user_or_id).score

  @doc "Returns a coarse label for UI and policy decisions."
  def personhood_level(user_or_id) do
    personhood_breakdown(user_or_id).level
  end

  @doc "Returns whether a user has enough personhood score for a policy gate."
  def sufficiently_human?(user_or_id, minimum_score \\ 40) when is_integer(minimum_score) do
    personhood_score(user_or_id) >= minimum_score
  end

  @doc "Returns the claim snippet users should publish for page-based proofs."
  def page_snippet(%Proof{} = proof), do: proof.challenge

  @doc "Returns DNS TXT record instructions for DNS-based proofs."
  def dns_txt_record(%Proof{verification_method: "dns"} = proof) do
    {"_atomine", proof.challenge}
  end

  def dns_txt_record(%Proof{}), do: nil

  @doc "Returns the DNS TXT host users should publish for a DNS proof."
  def dns_txt_host(%Proof{verification_method: "dns", subject: subject})
      when is_binary(subject) do
    "_atomine.#{String.trim(subject)}"
  end

  def dns_txt_host(%Proof{}), do: nil

  defp generate_challenge(%User{} = user, kind, subject) do
    token = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    handle = user.handle || user.username || "user-#{user.id}"
    subject = subject || ""
    payload = signed_proof_payload(user.id, handle, kind, subject, token)
    signature = sign_proof_payload(payload)

    Enum.join(
      [
        "Atomine identity claim",
        @proof_statement_version,
        "user=#{encode_proof_field("@#{handle}")}",
        "user_id=#{user.id}",
        "kind=#{encode_proof_field(kind)}",
        "subject=#{encode_proof_field(subject)}",
        "nonce=#{encode_proof_field(token)}",
        "sig=#{encode_proof_field(signature)}"
      ],
      " "
    )
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp put_default_session_fields(attrs, user) do
    score_breakdown = if user, do: personhood_breakdown(user), else: nil
    score = Map.get(attrs, "score") || (score_breakdown && score_breakdown.score) || 0
    decision = Map.get(attrs, "decision") || default_decision(score)

    attrs
    |> maybe_put_user_id(user)
    |> Map.put_new("context", "checkout")
    |> Map.put_new("status", default_session_status(decision))
    |> Map.put_new("decision", decision)
    |> Map.put_new("recommended_step_up", default_step_up(decision, score))
    |> Map.put_new("score", score)
    |> Map.put_new("level", Map.get(attrs, "level") || score_level(score))
    |> Map.put_new("signals", %{})
    |> Map.put_new("metadata", %{})
    |> Map.put_new("expires_at", DateTime.add(now(), 30, :minute))
  end

  defp maybe_put_user_id(attrs, %User{id: user_id}), do: Map.put_new(attrs, "user_id", user_id)
  defp maybe_put_user_id(attrs, nil), do: attrs

  defp insert_trust_session(attrs) do
    %TrustSession{}
    |> TrustSession.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, field, value) do
    where(query, [s], field(s, ^field) == ^value)
  end

  defp default_decision(score) when score >= 75, do: "allow"
  defp default_decision(score) when score >= 40, do: "step_up"
  defp default_decision(score) when score >= 15, do: "step_up"
  defp default_decision(_), do: "review"

  defp default_session_status("allow"), do: "completed"
  defp default_session_status("step_up"), do: "step_up"
  defp default_session_status(_), do: "pending"

  defp default_step_up("step_up", score) when score < 40, do: "passkey"
  defp default_step_up("step_up", _score), do: "email"
  defp default_step_up("review", _score), do: "proof"
  defp default_step_up(_, _score), do: "none"

  defp score_level(score), do: Scoring.level(score) |> Atom.to_string()

  defp connected_account_subject(%ConnectedAccount{} = connected_account) do
    "oauth:#{connected_account.provider}:#{connected_account.provider_account_id}"
  end

  defp dns_challenge_present?(proof) do
    host = dns_txt_host(proof)

    with true <- is_binary(host) and host != "",
         true <- proof_statement_valid?(proof),
         {:ok, records} <- lookup_txt_records(host) do
      Enum.any?(records, &String.contains?(&1, proof.challenge))
    else
      false -> {:error, :invalid_dns_subject}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lookup_txt_records(host) do
    host
    |> String.trim_trailing(".")
    |> String.to_charlist()
    |> :inet_res.lookup(:in, :txt)
    |> case do
      [] -> {:ok, []}
      records -> {:ok, Enum.map(records, &txt_record_to_string/1)}
    end
  rescue
    error -> {:error, error}
  end

  defp txt_record_to_string(record) when is_list(record) do
    record
    |> List.flatten()
    |> to_string()
  end

  defp txt_record_to_string(record), do: to_string(record)

  defp web_challenge_present?(proof) do
    url = proof.evidence_url || proof.subject

    with true <- proof_statement_valid?(proof),
         {:ok, uri} <- safe_web_proof_uri(url),
         {:ok, body} <- fetch_web_proof(uri) do
      String.contains?(body, proof.challenge)
    end
  end

  defp github_gist_challenge_present?(proof) do
    with true <- proof_statement_valid?(proof),
         {:ok, username} <- github_profile_username(proof.subject),
         {:ok, body} <- fetch_github_user_gists(username) do
      String.contains?(body, proof.challenge)
    end
  end

  defp github_profile_username(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))
    host = if is_binary(uri.host), do: String.downcase(uri.host), else: nil
    path_parts = uri.path |> to_string() |> String.split("/", trim: true)

    case {uri.scheme, host, path_parts} do
      {scheme, "github.com", [username | _]} when scheme in ["http", "https"] ->
        {:ok, username}

      _ ->
        {:error, :not_github_profile_url}
    end
  end

  defp github_profile_username(_), do: {:error, :not_github_profile_url}

  defp fetch_github_user_gists(username) do
    start_app(:inets)
    start_app(:ssl)

    url = ~c"https://api.github.com/users/#{username}/gists?per_page=100"

    headers = [
      {~c"user-agent", ~c"Elektrine-Atomine-Proofs"},
      {~c"accept", ~c"application/vnd.github+json"}
    ]

    request = {url, headers}
    http_options = [timeout: 5_000]
    options = [body_format: :binary]

    case :httpc.request(:get, request, http_options, options) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
        decode_user_gists_body(body)

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:github_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_user_gists_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_list(decoded) ->
        contents =
          decoded
          |> Enum.flat_map(&gist_file_raw_urls/1)
          |> Enum.flat_map(&fetch_gist_raw_file/1)
          |> Enum.join("\n")

        {:ok, contents}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_gist_response}
    end
  end

  defp gist_file_raw_urls(%{"files" => files}) when is_map(files) do
    files
    |> Map.values()
    |> Enum.map(fn file -> Map.get(file, "raw_url") end)
    |> Enum.filter(&is_binary/1)
  end

  defp gist_file_raw_urls(_), do: []

  defp fetch_gist_raw_file(raw_url) do
    with {:ok, uri} <- safe_web_proof_uri(raw_url),
         "gist.githubusercontent.com" <- String.downcase(uri.host || ""),
         {:ok, body} <- fetch_web_proof(uri) do
      [body]
    else
      _ -> []
    end
  end

  defp safe_web_proof_uri(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    cond do
      uri.scheme not in ["http", "https"] -> {:error, :unsupported_url_scheme}
      is_nil(uri.host) or uri.host == "" -> {:error, :missing_host}
      blocked_proof_host?(uri.host) -> {:error, :blocked_private_host}
      true -> {:ok, uri}
    end
  end

  defp safe_web_proof_uri(_), do: {:error, :invalid_url}

  defp blocked_proof_host?(host) do
    host = host |> String.trim_trailing(".") |> String.downcase()

    cond do
      host in ["localhost", "localhost.localdomain"] ->
        true

      String.ends_with?(host, ".local") ->
        true

      true ->
        host
        |> resolve_host_addresses()
        |> case do
          {:ok, addresses} -> Enum.any?(addresses, &blocked_address?/1)
          {:error, _reason} -> true
        end
    end
  end

  defp resolve_host_addresses(host) do
    host_chars = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(host_chars, family) do
          {:ok, values} -> values
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    case addresses do
      [] -> {:error, :host_not_resolved}
      values -> {:ok, values}
    end
  end

  defp blocked_address?({10, _, _, _}), do: true
  defp blocked_address?({127, _, _, _}), do: true
  defp blocked_address?({0, _, _, _}), do: true
  defp blocked_address?({169, 254, _, _}), do: true
  defp blocked_address?({172, second, _, _}) when second in 16..31, do: true
  defp blocked_address?({192, 168, _, _}), do: true
  defp blocked_address?({100, second, _, _}) when second in 64..127, do: true
  defp blocked_address?({192, 0, 0, _}), do: true
  defp blocked_address?({192, 0, 2, _}), do: true
  defp blocked_address?({198, 18, _, _}), do: true
  defp blocked_address?({198, 19, _, _}), do: true
  defp blocked_address?({198, 51, 100, _}), do: true
  defp blocked_address?({203, 0, 113, _}), do: true
  defp blocked_address?({224, _, _, _}), do: true
  defp blocked_address?({a, _, _, _}) when a >= 225, do: true
  defp blocked_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp blocked_address?({0xFE80, _, _, _, _, _, _, _}), do: true
  defp blocked_address?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  defp blocked_address?({0x2001, 0, _, _, _, _, _, _}), do: true
  defp blocked_address?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: true
  defp blocked_address?(_address), do: false

  defp fetch_web_proof(uri) do
    start_app(:inets)
    start_app(:ssl)

    request = {URI.to_string(uri) |> String.to_charlist(), []}
    http_options = [timeout: 5_000]
    options = [body_format: :binary]

    case :httpc.request(:get, request, http_options, options) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 -> {:ok, body}
      {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_app(app) do
    case Application.ensure_all_started(app) do
      {:ok, _started} -> :ok
      {:error, {:already_started, ^app}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp proof_statement_valid?(%Proof{challenge: challenge} = proof) when is_binary(challenge) do
    case parse_signed_proof_statement(challenge) do
      {:ok, fields} ->
        with :ok <- signed_fields_match_proof(fields, proof) do
          payload =
            signed_proof_payload(
              fields["user_id"],
              fields["user"] |> String.trim_leading("@"),
              fields["kind"],
              fields["subject"],
              fields["nonce"]
            )

          if secure_compare(sign_proof_payload(payload), fields["sig"]) do
            true
          else
            {:error, :invalid_proof_signature}
          end
        end

      :legacy ->
        true

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp proof_statement_valid?(%Proof{}), do: {:error, :invalid_proof_statement}

  defp parse_signed_proof_statement("Atomine identity claim " <> rest) do
    parse_signed_proof_statement_fields(rest)
  end

  defp parse_signed_proof_statement("Atomine personhood proof " <> rest) do
    parse_signed_proof_statement_fields(rest)
  end

  defp parse_signed_proof_statement(_challenge), do: :legacy

  defp parse_signed_proof_statement_fields(rest) do
    case String.split(rest, " ", trim: true) do
      [@proof_statement_version | encoded_fields] ->
        fields =
          Map.new(encoded_fields, fn field ->
            case String.split(field, "=", parts: 2) do
              [key, value] -> {key, decode_proof_field(value)}
              [key] -> {key, ""}
            end
          end)

        if Enum.all?(~w(user user_id kind subject nonce sig), &present_field?(fields, &1)) do
          {:ok, fields}
        else
          {:error, :invalid_proof_statement}
        end

      _ ->
        {:error, :unsupported_proof_statement}
    end
  end

  defp signed_fields_match_proof(fields, proof) do
    cond do
      fields["user_id"] != to_string(proof.user_id) -> {:error, :proof_user_mismatch}
      fields["kind"] != proof.kind -> {:error, :proof_kind_mismatch}
      fields["subject"] != proof.subject -> {:error, :proof_subject_mismatch}
      true -> :ok
    end
  end

  defp present_field?(fields, key) do
    case Map.get(fields, key) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp signed_proof_payload(user_id, handle, kind, subject, nonce) do
    Enum.join(
      [
        "atomine-proof:#{@proof_statement_version}",
        "user_id=#{user_id}",
        "user=#{handle}",
        "kind=#{kind}",
        "subject=#{subject}",
        "nonce=#{nonce}"
      ],
      "\n"
    )
  end

  defp sign_proof_payload(payload) do
    :crypto.mac(:hmac, :sha256, proof_signing_secret(), payload)
    |> Base.url_encode64(padding: false)
  end

  defp proof_signing_secret do
    Elektrine.RuntimeSecrets.secret_key_base() || "atomine-dev-proof-signing-secret"
  end

  defp encode_proof_field(value), do: value |> to_string() |> URI.encode_www_form()

  defp decode_proof_field(value) do
    URI.decode_www_form(value)
  rescue
    ArgumentError -> value
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_, _), do: false

  defp mark_check_failed(%Proof{proof_mode: "live"} = proof, notes) do
    mark_live_stale(proof, notes)
  end

  defp mark_check_failed(%Proof{} = proof, notes) do
    proof
    |> Proof.changeset(%{checked_at: now(), review_notes: notes})
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:error, {:not_found, updated}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp normalize_kind(kind) when is_binary(kind), do: kind |> String.trim() |> String.downcase()
  defp normalize_kind(_), do: ""

  defp normalize_method(method) when is_binary(method),
    do: method |> String.trim() |> String.downcase()

  defp normalize_method(_), do: "manual"

  defp normalize_proof_mode("live"), do: "live"
  defp normalize_proof_mode(_), do: "snapshot"

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(500)
  defp normalize_limit(_), do: 100

  defp default_method_for_kind("dns", _subject), do: "dns"
  defp default_method_for_kind("web", _subject), do: "page"
  defp default_method_for_kind("social", subject), do: social_method_for_subject(subject)
  defp default_method_for_kind(_kind, _subject), do: "manual"

  defp social_method_for_subject(subject) do
    case github_profile_username(subject) do
      {:ok, _username} -> "github_gist"
      {:error, _reason} -> "page"
    end
  end

  defp proof_metadata(metadata, verification_method, challenge) when is_map(metadata) do
    Map.merge(
      %{"verification_snippet" => challenge, "verification_method" => verification_method},
      metadata
    )
  end

  defp proof_metadata(_metadata, verification_method, challenge) do
    %{"verification_snippet" => challenge, "verification_method" => verification_method}
  end

  defp initial_live_status("live"), do: "stale"
  defp initial_live_status(_), do: nil

  defp verified_live_status(%Proof{proof_mode: "live"}), do: "active"
  defp verified_live_status(%Proof{} = proof), do: proof.live_status

  defp rejected_live_status(%Proof{proof_mode: "live"}), do: "inactive"
  defp rejected_live_status(%Proof{} = proof), do: proof.live_status

  defp revoked_live_status(%Proof{proof_mode: "live"}), do: "inactive"
  defp revoked_live_status(%Proof{} = proof), do: proof.live_status

  defp live_timestamp(%Proof{proof_mode: "live"}, now), do: now
  defp live_timestamp(%Proof{} = proof, _now), do: proof.last_seen_at

  defp next_check_at(%Proof{proof_mode: "live"}, now),
    do: DateTime.add(now, @live_check_interval_days, :day)

  defp next_check_at(%Proof{} = proof, _now), do: proof.next_check_at

  defp stale_at(%Proof{proof_mode: "live"}, now),
    do: DateTime.add(now, @live_stale_after_days, :day)

  defp stale_at(%Proof{} = proof, _now), do: proof.stale_at

  defp reviewer_id(%User{id: id}), do: id
  defp reviewer_id(id) when is_integer(id), do: id
  defp reviewer_id(_), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
