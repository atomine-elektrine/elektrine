defmodule Atomine.CreditPolicy do
  @moduledoc "Policy helpers that translate account trust into Atomine Credit costs."

  alias Atomine.Credits
  alias Elektrine.Accounts.User
  alias Elektrine.{Friends, Repo}

  @dm_credit "dm_credit"
  @email_credit "email_credit"
  @first_dm_action "first_dm"
  @send_email_action "send_email"
  @first_dm_cost 1
  @send_email_cost 5

  @doc "Returns whether the first-DM credit gate is enabled."
  def dm_gate_enabled? do
    :atomine
    |> Application.get_env(:credits, [])
    |> Keyword.get(:dm_gate_enabled, false)
  end

  @doc "Returns whether the outbound email credit gate is enabled."
  def email_gate_enabled? do
    :atomine
    |> Application.get_env(:credits, [])
    |> Keyword.get(:email_gate_enabled, false)
  end

  @doc "Returns current built-in action pricing for UI/API discovery."
  def action_prices do
    [
      %{
        action: @first_dm_action,
        label: "First DM",
        atomine_cost: @first_dm_cost,
        restricted_credit_type: @dm_credit,
        restricted_cost: 1,
        gate_enabled: dm_gate_enabled?(),
        free_for: "TL1+ and admins"
      },
      %{
        action: @send_email_action,
        label: "External email",
        atomine_cost: @send_email_cost,
        restricted_credit_type: @email_credit,
        restricted_cost: 1,
        gate_enabled: email_gate_enabled?(),
        free_for: "TL1+ and admins"
      }
    ]
  end

  @doc "Spends a DM Credit for a first DM against an arbitrary audience."
  def spend_first_dm_credit(sender_id, recipient, opts \\ [])

  def spend_first_dm_credit(sender_id, recipient_id, opts) when is_integer(recipient_id) do
    opts = Keyword.put(opts, :local_recipient_id, recipient_id)
    spend_first_dm_credit(sender_id, "user:#{recipient_id}", opts)
  end

  def spend_first_dm_credit(sender_id, audience, opts) when is_binary(audience) do
    case first_dm_credit_requirement(sender_id, opts) do
      :free ->
        :ok

      :required ->
        case Credits.spend_action(
               sender_id,
               @dm_credit,
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

  @doc "Spends an Email Credit when an external outbound send needs one."
  def spend_email_credit(sender_id, audience, opts \\ []) when is_binary(audience) do
    case email_credit_requirement(sender_id, opts) do
      :free ->
        :ok

      :required ->
        case Credits.spend_action(
               sender_id,
               @email_credit,
               @send_email_cost,
               @send_email_action,
               audience,
               idempotency_key: "#{@send_email_action}:#{sender_id}:#{audience}"
             ) do
          {:ok, _spend} -> :ok
          {:error, :insufficient_credits} -> {:error, :insufficient_email_credits}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp first_dm_credit_requirement(sender_id, opts) do
    if dm_gate_enabled?() do
      sender = Repo.get(User, sender_id)
      local_recipient_id = Keyword.get(opts, :local_recipient_id)

      cond do
        is_nil(sender) ->
          {:error, :user_not_found}

        trusted_for_free_dm?(sender) ->
          :free

        is_integer(local_recipient_id) and Friends.are_friends?(sender_id, local_recipient_id) ->
          :free

        true ->
          :required
      end
    else
      :free
    end
  end

  defp email_credit_requirement(sender_id, _opts) do
    if email_gate_enabled?() do
      sender = Repo.get(User, sender_id)

      cond do
        is_nil(sender) -> {:error, :user_not_found}
        trusted_for_free_email?(sender) -> :free
        true -> :required
      end
    else
      :free
    end
  end

  defp trusted_for_free_dm?(%User{is_admin: true}), do: true
  defp trusted_for_free_dm?(%User{trust_level: trust_level}) when trust_level >= 1, do: true
  defp trusted_for_free_dm?(_user), do: false

  defp trusted_for_free_email?(%User{is_admin: true}), do: true
  defp trusted_for_free_email?(%User{trust_level: trust_level}) when trust_level >= 1, do: true
  defp trusted_for_free_email?(_user), do: false
end
