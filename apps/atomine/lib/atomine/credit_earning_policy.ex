defmodule Atomine.CreditEarningPolicy do
  @moduledoc "Policy for converting anti-abuse proof systems into Atomine Credit grants."

  import Ecto.Query, warn: false

  alias Atomine.{CreditLedgerEntry, Credits, Proof}
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  @pow_daily_grant 1
  @pow_daily_claim_limit 20
  @credit_earning_actions ~w(verified_proof proof_of_work)

  @daily_earning_caps %{
    0 => 20,
    1 => 50,
    2 => 100,
    3 => 250
  }

  @balance_caps %{
    0 => 25,
    1 => 100,
    2 => 250,
    3 => 1_000
  }

  @proof_grants %{
    "dns" => 10,
    "web" => 8,
    "social" => 5,
    "passkey" => 5,
    "payment" => 15,
    "vouch" => 10,
    "manual" => 10
  }

  @doc "Returns the proof-of-X earning systems for product/UI discovery."
  def earning_paths do
    [
      %{
        key: "proof_of_personhood",
        label: "Proof of personhood/control",
        status: :active,
        summary: "Verify DNS, web, social, GitHub, passkey, payment, or reviewed proof signals.",
        reward: "5-15 Identity Credits per verified proof, once per proof."
      },
      %{
        key: "proof_of_stake",
        label: "Proof of stake",
        status: :planned,
        summary: "Lock stake for higher action capacity; abusive use can be slashed.",
        reward: "Planned."
      },
      %{
        key: "proof_of_work",
        label: "Proof of work",
        status: :active,
        summary: "Spend computational or delivery-cost work to earn small temporary capacity.",
        reward:
          "#{@pow_daily_grant} Identity Credit per run, up to #{@pow_daily_claim_limit} per day."
      },
      %{
        key: "proof_of_reputation",
        label: "Proof of reputation",
        status: :planned,
        summary: "Clean account age, low reports, accepted messages, and good delivery history.",
        reward: "Planned."
      },
      %{
        key: "proof_of_service",
        label: "Proof of service",
        status: :planned,
        summary: "Contribute useful network, moderation, or support work.",
        reward: "Planned."
      }
    ]
  end

  @doc "Returns the one-time Atomine Credit grant for a verified proof kind."
  def verified_proof_grant_amount(kind), do: Map.get(@proof_grants, to_string(kind), 0)

  @doc "Returns the daily Atomine Credit grant for a proof-of-work claim."
  def proof_of_work_grant_amount, do: @pow_daily_grant

  @doc "Returns the maximum proof-of-work credit claims per day."
  def proof_of_work_daily_claim_limit, do: @pow_daily_claim_limit

  @doc "Returns the durable anti-abuse reward key for a proof."
  def canonical_proof_reference(%Proof{} = proof) do
    proof
    |> canonical_proof_key()
    |> safe_reference_id()
  end

  @doc "Grants Atomine Credits once when an eligible proof is verified."
  def grant_for_verified_proof(%Proof{} = proof) do
    amount = verified_proof_grant_amount(proof.kind)

    cond do
      proof.claim_type != "positive" ->
        {:ok, :not_eligible}

      proof.status != "verified" ->
        {:ok, :not_verified}

      amount <= 0 ->
        {:ok, :not_eligible}

      true ->
        canonical_key = canonical_proof_key(proof)
        reference_id = safe_reference_id(canonical_key)

        grant_once_per_claim(
          proof.user_id,
          amount,
          "verified_proof:#{proof.kind}",
          action: "verified_proof",
          reference_type: "atomine_proof_claim",
          reference_id: reference_id,
          metadata: %{
            "proof_kind" => proof.kind,
            "proof_subject" => proof.subject,
            "proof_method" => proof.verification_method,
            "proof_id" => proof.id,
            "canonical_key" => canonical_key
          }
        )
    end
  end

  @doc "Grants one proof-of-work Atomine Credit, capped per day."
  def grant_for_proof_of_work(user_id, opts \\ []) when is_integer(user_id) do
    date = Keyword.get(opts, :date, Date.utc_today())
    claims_today = proof_of_work_claims_today(user_id, date)

    if claims_today >= @pow_daily_claim_limit do
      {:ok, :daily_claim_limit_reached}
    else
      claim_number = claims_today + 1

      grant_once_per_claim(
        user_id,
        @pow_daily_grant,
        "proof_of_work",
        action: "proof_of_work",
        date: date,
        reference_type: "atomine_pow_claim",
        reference_id: "#{user_id}:#{Date.to_iso8601(date)}:#{claim_number}",
        metadata: %{
          "date" => Date.to_iso8601(date),
          "difficulty" => Keyword.get(opts, :difficulty),
          "claim_number" => claim_number,
          "daily_claim_limit" => @pow_daily_claim_limit
        }
      )
    end
  end

  defp grant_once_per_claim(user_id, amount, reason, opts) do
    reference_type = Keyword.fetch!(opts, :reference_type)
    reference_id = Keyword.fetch!(opts, :reference_id)

    cond do
      existing_user_grant?(user_id, reason, reference_type, reference_id) ->
        {:ok, :already_granted}

      existing_global_proof_claim?(reference_type, reference_id) ->
        {:ok, :already_rewarded}

      true ->
        case check_earning_caps(user_id, amount, Keyword.get(opts, :date, Date.utc_today())) do
          :ok ->
            Credits.grant_once(
              user_id,
              :atomine_credit,
              amount,
              reason,
              opts
            )

          {:error, reason} ->
            {:ok, reason}
        end
    end
  end

  defp existing_user_grant?(user_id, reason, reference_type, reference_id) do
    CreditLedgerEntry
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.credit_type == "atomine_credit")
    |> where([e], e.reason == ^reason)
    |> where([e], e.reference_type == ^reference_type)
    |> where([e], e.reference_id == ^to_string(reference_id))
    |> where([e], e.amount > 0)
    |> Repo.exists?()
  end

  defp existing_global_proof_claim?("atomine_proof_claim", reference_id) do
    CreditLedgerEntry
    |> where([e], e.credit_type == "atomine_credit")
    |> where([e], e.reference_type == "atomine_proof_claim")
    |> where([e], e.reference_id == ^to_string(reference_id))
    |> where([e], e.amount > 0)
    |> Repo.exists?()
  end

  defp existing_global_proof_claim?(_reference_type, _reference_id), do: false

  defp check_earning_caps(user_id, amount, date) do
    %{daily: daily_cap, balance: balance_cap} = credit_caps(user_id)

    cond do
      cap_exceeded?(daily_cap, earned_today(user_id, date), amount) ->
        {:error, :daily_earning_cap_reached}

      cap_exceeded?(balance_cap, Credits.balance(user_id, :atomine_credit), amount) ->
        {:error, :balance_cap_reached}

      true ->
        :ok
    end
  end

  defp cap_exceeded?(nil, _current, _amount), do: false
  defp cap_exceeded?(cap, current, amount), do: current + amount > cap

  defp earned_today(user_id, date) do
    {start_at, end_at} = day_bounds(date)

    CreditLedgerEntry
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.credit_type == "atomine_credit")
    |> where([e], e.amount > 0)
    |> where([e], e.action in ^@credit_earning_actions)
    |> where([e], e.inserted_at >= ^start_at and e.inserted_at < ^end_at)
    |> select([e], coalesce(sum(e.amount), 0))
    |> Repo.one()
  end

  defp proof_of_work_claims_today(user_id, date) do
    {start_at, end_at} = day_bounds(date)

    CreditLedgerEntry
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.credit_type == "atomine_credit")
    |> where([e], e.reason == "proof_of_work")
    |> where([e], e.reference_type == "atomine_pow_claim")
    |> where([e], e.amount > 0)
    |> where([e], e.inserted_at >= ^start_at and e.inserted_at < ^end_at)
    |> select([e], count(e.id))
    |> Repo.one()
  end

  defp day_bounds(date) do
    start_at = DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.truncate(:second)
    {start_at, DateTime.add(start_at, 1, :day)}
  end

  defp credit_caps(user_id) do
    case Repo.get(User, user_id) do
      %User{is_admin: true} ->
        %{daily: nil, balance: nil}

      %User{trust_level: trust_level} ->
        tier = trust_level |> Kernel.||(0) |> min(3) |> max(0)
        %{daily: Map.fetch!(@daily_earning_caps, tier), balance: Map.fetch!(@balance_caps, tier)}

      _ ->
        %{daily: Map.fetch!(@daily_earning_caps, 0), balance: Map.fetch!(@balance_caps, 0)}
    end
  end

  defp canonical_proof_key(%Proof{kind: "dns", subject: subject}) do
    "dns:#{canonical_dns_subject(subject)}"
  end

  defp canonical_proof_key(%Proof{kind: "web"} = proof) do
    "web:#{canonical_url(proof.evidence_url || proof.subject)}"
  end

  defp canonical_proof_key(%Proof{verification_method: "oauth", metadata: metadata}) do
    provider = metadata_value(metadata, "provider")
    provider_account_id = metadata_value(metadata, "provider_account_id")

    "social:oauth:#{String.downcase(provider)}:#{provider_account_id}"
  end

  defp canonical_proof_key(%Proof{kind: "social", subject: subject}) do
    "social:#{canonical_url(subject)}"
  end

  defp canonical_proof_key(%Proof{kind: kind, subject: subject}) do
    "#{kind}:#{subject |> to_string() |> String.trim() |> String.downcase()}"
  end

  defp canonical_dns_subject(subject) do
    subject
    |> to_string()
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp canonical_url(value) do
    value = String.trim(to_string(value))

    case URI.parse(value) do
      %URI{host: host} = uri when is_binary(host) ->
        scheme = uri.scheme |> to_string() |> String.downcase()
        host = String.downcase(host)
        port = canonical_port(uri.scheme, uri.port)
        path = canonical_path(uri.path)

        [scheme, "://", host, port, path]
        |> IO.iodata_to_binary()
        |> String.trim_trailing("/")

      _ ->
        value
    end
  end

  defp canonical_port("http", 80), do: ""
  defp canonical_port("https", 443), do: ""
  defp canonical_port(_scheme, nil), do: ""
  defp canonical_port(_scheme, port), do: ":#{port}"

  defp canonical_path(nil), do: "/"
  defp canonical_path(""), do: "/"
  defp canonical_path(path), do: URI.decode(path)

  defp metadata_value(metadata, key) when is_map(metadata) do
    metadata
    |> Map.get(key, "")
    |> to_string()
  end

  defp metadata_value(_metadata, _key), do: ""

  defp safe_reference_id(value) do
    value = to_string(value)

    if String.length(value) <= 200 do
      value
    else
      hash = :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
      "sha256:#{hash}"
    end
  end
end
