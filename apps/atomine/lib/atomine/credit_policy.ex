defmodule Atomine.CreditPolicy do
  @moduledoc "Policy helpers that translate account trust into Atomine Credit costs."

  alias Atomine.Credits
  alias Elektrine.Accounts.Capabilities

  @first_dm_action "first_dm"
  @send_email_action "send_email"
  @first_dm_cost 1
  @send_email_cost 1

  @doc "Returns whether the first-DM credit gate is enabled."
  def dm_gate_enabled?, do: Capabilities.credit_gate_enabled?(:dm)

  @doc "Returns whether the outbound email credit gate is enabled."
  def email_gate_enabled?, do: Capabilities.credit_gate_enabled?(:email)

  @doc "Returns current built-in action pricing for UI/API discovery."
  def action_prices, do: Capabilities.action_prices()

  @doc "Spends Atomine Credits for a first DM against an arbitrary audience."
  def spend_first_dm_credit(sender_id, recipient, opts \\ [])

  def spend_first_dm_credit(sender_id, recipient_id, opts) when is_integer(recipient_id) do
    opts = Keyword.put(opts, :local_recipient_id, recipient_id)
    spend_first_dm_credit(sender_id, "user:#{recipient_id}", opts)
  end

  def spend_first_dm_credit(sender_id, audience, opts) when is_binary(audience) do
    case Capabilities.first_dm_credit_requirement(sender_id, opts) do
      :free ->
        :ok

      :required ->
        case Credits.spend(
               sender_id,
               :atomine_credit,
               @first_dm_cost,
               @first_dm_action,
               audience,
               idempotency_key: "#{@first_dm_action}:#{sender_id}:#{audience}"
             ) do
          {:ok, _spend} -> :ok
          {:error, :insufficient_credits} -> {:error, :insufficient_dm_credits}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Spends Atomine Credits when an external outbound send needs them."
  def spend_email_credit(sender_id, audience, opts \\ []) when is_binary(audience) do
    case Capabilities.email_credit_requirement(sender_id, opts) do
      :free ->
        :ok

      :required ->
        case Credits.spend(
               sender_id,
               :atomine_credit,
               @send_email_cost,
               @send_email_action,
               audience,
               idempotency_key: Keyword.get(opts, :idempotency_key)
             ) do
          {:ok, _spend} -> :ok
          {:error, :insufficient_credits} -> {:error, :insufficient_email_credits}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
