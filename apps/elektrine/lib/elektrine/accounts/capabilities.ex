defmodule Elektrine.Accounts.Capabilities do
  @moduledoc """
  Central account capability policy.

  Proofs and clean account history feed reputation. Reputation, trust level,
  restrictions, and credits then determine what an account can do and what
  risky actions cost.
  """

  alias Elektrine.Accounts.User
  alias Elektrine.{Friends, Repo, System}

  @personhood_module Module.concat([Atomine, Personhood])
  @credits_module Module.concat([Atomine, Credits])
  @credit_earning_policy_module Module.concat([Atomine, CreditEarningPolicy])

  @first_dm_action "first_dm"
  @send_email_action "send_email"
  @first_dm_cost 1
  @send_email_cost 1

  @email_tier_limits %{
    day_1: %{minute: 1, hour: 5, day: 10, recipients: 3},
    days_2_3: %{minute: 2, hour: 8, day: 10, recipients: 5},
    days_4_7: %{minute: 2, hour: 15, day: 10, recipients: 10},
    week_2: %{minute: 3, hour: 25, day: 10, recipients: 15},
    weeks_3_4: %{minute: 3, hour: 35, day: 10, recipients: 20},
    tl1: %{minute: 5, hour: 50, day: 200, recipients: 50},
    tl2: %{minute: 10, hour: 100, day: 500, recipients: 100},
    tl3_plus: %{minute: 15, hour: 150, day: 1000, recipients: 200}
  }

  @vpn_default_bandwidth_quota_bytes 10_737_418_240
  @vpn_default_rate_limit_mbps 50

  @doc "Returns the complete policy snapshot for an account."
  def snapshot(user_or_id, opts \\ []) do
    user = load_user(user_or_id)
    reputation = reputation_snapshot(user)
    credits = credit_snapshot(user)

    %{
      user_id: user && user.id,
      trust_level: trust_level(user),
      effective_trust_level: effective_trust_level(user, reputation),
      reputation: reputation,
      proofs: %{
        verified_count: reputation.verified_proof_count,
        verified_kinds: reputation.verified_proof_kinds
      },
      credits: credits,
      restrictions: restrictions(user),
      capabilities: %{
        email: email_capability(user),
        dm: dm_capability(user, opts),
        vpn: vpn_capability(user, opts),
        invites: invite_capability(user)
      }
    }
  end

  @doc "Returns current built-in action pricing for UI/API discovery."
  def action_prices do
    [
      %{
        action: @first_dm_action,
        label: "First DM",
        atomine_cost: @first_dm_cost,
        gate_enabled: credit_gate_enabled?(:dm),
        free_for: "TL1+ and admins"
      },
      %{
        action: @send_email_action,
        label: "External email",
        atomine_cost: @send_email_cost,
        gate_enabled: credit_gate_enabled?(:email),
        free_for: "TL3+ and admins"
      }
    ]
  end

  def credit_gate_enabled?(:dm) do
    :atomine
    |> Application.get_env(:credits, [])
    |> Keyword.get(:dm_gate_enabled, false)
  end

  def credit_gate_enabled?(:email) do
    :atomine
    |> Application.get_env(:credits, [])
    |> Keyword.get(:email_gate_enabled, false)
  end

  def credit_gate_enabled?(_gate), do: false

  @doc "Returns whether a first DM is free or requires credits."
  def first_dm_credit_requirement(user_or_id, opts \\ []) do
    if credit_gate_enabled?(:dm) do
      user = load_user(user_or_id)
      local_recipient_id = Keyword.get(opts, :local_recipient_id)

      cond do
        is_nil(user) ->
          {:error, :user_not_found}

        trusted_for_free_action?(user) ->
          :free

        is_integer(local_recipient_id) and Friends.are_friends?(user.id, local_recipient_id) ->
          :free

        true ->
          :required
      end
    else
      :free
    end
  end

  @doc "Returns whether an external email send is free or requires credits."
  def email_credit_requirement(user_or_id, _opts \\ []) do
    if credit_gate_enabled?(:email) do
      case load_user(user_or_id) do
        nil -> {:error, :user_not_found}
        user -> if trusted_for_free_email?(user), do: :free, else: :required
      end
    else
      :free
    end
  end

  @doc "Returns the email send tier and limits for a user."
  def email_limits(user_or_id) do
    user = load_user(user_or_id)
    tier = email_tier(user)
    limits = Map.fetch!(@email_tier_limits, tier)

    %{
      tier: tier,
      minute_limit: limits.minute,
      hour_limit: limits.hour,
      day_limit: limits.day,
      recipient_limit: limits.recipients
    }
  end

  @doc "Returns the configured platform-wide VPN minimum trust level."
  def vpn_minimum_trust_level, do: System.module_min_trust_level(:vpn)

  @doc "Returns VPN access and quota policy for a user."
  def vpn_capability(user_or_id, opts \\ []) do
    user = load_user(user_or_id)
    required_trust_level = vpn_required_trust_level(opts)

    base = %{
      required_trust_level: required_trust_level,
      bandwidth_quota_bytes: @vpn_default_bandwidth_quota_bytes,
      rate_limit_mbps: @vpn_default_rate_limit_mbps
    }

    cond do
      is_nil(user) ->
        Map.merge(base, %{allowed: false, reason: :user_not_found})

      user.is_admin ->
        Map.merge(base, %{allowed: true, reason: nil})

      user.banned ->
        Map.merge(base, %{allowed: false, reason: :banned})

      user.suspended ->
        Map.merge(base, %{allowed: false, reason: :suspended})

      trust_level(user) < required_trust_level ->
        Map.merge(base, %{allowed: false, reason: :insufficient_trust_level})

      true ->
        Map.merge(base, %{allowed: true, reason: nil})
    end
  end

  @doc "Returns true when a user can access VPN under the current policy."
  def vpn_allowed?(user_or_id, opts \\ []), do: vpn_capability(user_or_id, opts).allowed

  defp dm_capability(user, opts) do
    requirement = first_dm_credit_requirement(user, opts)

    %{
      first_dm_credit_requirement: requirement,
      first_dm_atomine_cost: @first_dm_cost
    }
  end

  defp email_capability(user) do
    limits = email_limits(user)
    requirement = email_credit_requirement(user)

    %{
      allowed: email_allowed?(user),
      reason: email_block_reason(user),
      tier: limits.tier,
      minute_limit: limits.minute_limit,
      hour_limit: limits.hour_limit,
      day_limit: limits.day_limit,
      recipient_limit: limits.recipient_limit,
      external_send_credit_requirement: requirement,
      external_send_atomine_cost: @send_email_cost
    }
  end

  defp invite_capability(nil) do
    %{self_service_allowed: false, min_trust_level: System.self_service_invite_min_trust_level()}
  end

  defp invite_capability(%User{} = user) do
    min_trust_level = System.self_service_invite_min_trust_level()

    %{
      self_service_allowed: user.is_admin || trust_level(user) >= min_trust_level,
      min_trust_level: min_trust_level
    }
  end

  defp credit_snapshot(nil) do
    %{
      available?: atomine_module_loaded?(@credits_module),
      balances: %{},
      rows: [],
      action_prices: [],
      earning_paths: []
    }
  end

  defp credit_snapshot(%User{id: user_id}) do
    if atomine_module_loaded?(@credits_module) do
      credit_types = ["atomine_credit"]
      accounts = Atomine.Credits.list_accounts(user_id)
      balances = Map.new(accounts, &{&1.credit_type, &1.balance})

      rows =
        Enum.map(credit_types, fn credit_type ->
          %{
            type: credit_type,
            label: credit_label(credit_type),
            balance: Map.get(balances, credit_type, 0)
          }
        end)

      %{
        available?: true,
        balances: Map.new(rows, &{&1.type, &1.balance}),
        rows: rows,
        action_prices: action_prices(),
        earning_paths: credit_earning_paths()
      }
    else
      %{available?: false, balances: %{}, rows: [], action_prices: [], earning_paths: []}
    end
  end

  defp credit_earning_paths do
    if atomine_module_loaded?(@credit_earning_policy_module) do
      Atomine.CreditEarningPolicy.earning_paths()
    else
      []
    end
  end

  defp reputation_snapshot(nil) do
    breakdown = empty_reputation_breakdown()

    %{
      score: breakdown.score,
      level: breakdown.level,
      verified_proof_count: 0,
      verified_proof_kinds: [],
      breakdown: breakdown
    }
  end

  defp reputation_snapshot(%User{} = user) do
    breakdown = personhood_breakdown(user)

    %{
      score: breakdown.score,
      level: breakdown.level,
      verified_proof_count: breakdown.verified_proof_count,
      verified_proof_kinds: breakdown.verified_proof_kinds,
      breakdown: breakdown
    }
  end

  defp personhood_breakdown(user) do
    if atomine_module_loaded?(@personhood_module) do
      Atomine.Personhood.personhood_breakdown(user)
    else
      empty_reputation_breakdown()
    end
  end

  defp restrictions(nil) do
    %{banned: false, suspended: false, email_sending_restricted: false}
  end

  defp restrictions(%User{} = user) do
    %{
      banned: user.banned || false,
      suspended: user.suspended || false,
      email_sending_restricted: user.email_sending_restricted || false,
      email_rate_limit_violations: user.email_rate_limit_violations || 0,
      email_restriction_reason: user.email_restriction_reason
    }
  end

  defp email_allowed?(%User{} = user) do
    !user.banned && !user.suspended && !user.email_sending_restricted
  end

  defp email_allowed?(_), do: false

  defp email_block_reason(nil), do: :user_not_found
  defp email_block_reason(%User{banned: true}), do: :banned
  defp email_block_reason(%User{suspended: true}), do: :suspended
  defp email_block_reason(%User{email_sending_restricted: true}), do: :email_sending_restricted
  defp email_block_reason(%User{}), do: nil

  defp email_tier(nil), do: :day_1

  defp email_tier(%User{} = user) do
    account_age_days = account_age_days(user.inserted_at)
    trust_level = effective_trust_level(user)

    cond do
      trust_level >= 3 -> :tl3_plus
      trust_level == 2 -> :tl2
      trust_level == 1 -> :tl1
      account_age_days < 1 -> :day_1
      account_age_days < 3 -> :days_2_3
      account_age_days < 7 -> :days_4_7
      account_age_days < 14 -> :week_2
      account_age_days < 30 -> :weeks_3_4
      true -> :weeks_3_4
    end
  end

  defp vpn_required_trust_level(opts) do
    server_min_trust_level = Keyword.get(opts, :server_min_trust_level, 0) || 0
    max(vpn_minimum_trust_level(), server_min_trust_level)
  end

  defp trusted_for_free_action?(%User{is_admin: true}), do: true
  defp trusted_for_free_action?(%User{} = user), do: effective_trust_level(user) >= 1

  defp trusted_for_free_email?(%User{is_admin: true}), do: true
  defp trusted_for_free_email?(%User{} = user), do: effective_trust_level(user) >= 3

  defp effective_trust_level(%User{} = user) do
    effective_trust_level(user, reputation_snapshot(user))
  end

  defp effective_trust_level(%User{} = user, reputation) do
    max(trust_level(user), reputation_trust_level(reputation))
  end

  defp effective_trust_level(_user, _reputation), do: 0

  defp reputation_trust_level(%{level: :high}), do: 3
  defp reputation_trust_level(%{level: :medium}), do: 2
  defp reputation_trust_level(%{level: :low}), do: 1
  defp reputation_trust_level(_reputation), do: 0

  defp trust_level(%User{trust_level: trust_level}) when is_integer(trust_level), do: trust_level
  defp trust_level(_), do: 0

  defp load_user(%User{} = user), do: user
  defp load_user(user_id) when is_integer(user_id), do: Repo.get(User, user_id)
  defp load_user(_), do: nil

  defp account_age_days(%DateTime{} = inserted_at),
    do: DateTime.diff(DateTime.utc_now(), inserted_at, :day)

  defp account_age_days(%NaiveDateTime{} = inserted_at) do
    inserted_at
    |> DateTime.from_naive!("Etc/UTC")
    |> account_age_days()
  end

  defp account_age_days(_), do: 0

  defp atomine_module_loaded?(module), do: Code.ensure_loaded?(module)

  defp credit_label("atomine_credit"), do: "Identity Credits"

  defp credit_label(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp empty_reputation_breakdown do
    %{
      score: 0,
      raw_score: 0,
      level: :unknown,
      positive: %{
        proofs: 0,
        proof_diversity: 0,
        account_age: 0,
        security: 0,
        account_history: 0,
        platform_trust: 0
      },
      penalties: %{account_restrictions: 0, onion_registration: 0, proof_rejections: 0},
      verified_proof_count: 0,
      verified_proof_kinds: []
    }
  end
end
