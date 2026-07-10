defmodule Elektrine.Email.InboundAuthentication do
  @moduledoc """
  Normalizes inbound SPF/DKIM/DMARC authentication results.

  Haraka and future inbound providers can pass their auth result payloads through
  this module so filtering, quarantine, and UI code consume one shape.
  """

  @result_atoms %{
    "pass" => :pass,
    "fail" => :fail,
    "softfail" => :softfail,
    "neutral" => :neutral,
    "none" => :none,
    "temperror" => :temperror,
    "permerror" => :permerror
  }

  def normalize(results) when is_map(results) do
    %{
      spf: normalize_result(results[:spf] || results["spf"]),
      dkim: normalize_result(results[:dkim] || results["dkim"]),
      dmarc: normalize_result(results[:dmarc] || results["dmarc"]),
      arc: normalize_result(results[:arc] || results["arc"]),
      aligned?: truthy?(results[:aligned] || results["aligned"])
    }
  end

  def normalize(_), do: normalize(%{})

  def authenticated?(results) do
    normalized = normalize(results)

    cond do
      normalized.dmarc == :pass -> true
      normalized.dmarc == :fail -> false
      normalized.arc == :pass -> true
      normalized.aligned? -> normalized.spf == :pass or normalized.dkim == :pass
      true -> false
    end
  end

  def policy_decision(results) do
    normalized = normalize(results)
    policy = Application.get_env(:elektrine, :inbound_email_auth_policy, :monitor)

    cond do
      authenticated?(normalized) ->
        %{action: :accept, authentication: normalized}

      policy in [:quarantine, "quarantine"] ->
        %{action: :quarantine, authentication: normalized}

      policy in [:reject, "reject"] ->
        %{action: :reject, authentication: normalized}

      true ->
        %{action: :accept, authentication: normalized}
    end
  end

  defp normalize_result(result) when is_atom(result), do: normalize_result(Atom.to_string(result))

  defp normalize_result(result) when is_binary(result) do
    value = result |> String.downcase() |> String.trim()
    Map.get(@result_atoms, value, :none)
  end

  defp normalize_result(_), do: :none

  defp truthy?(value), do: value in [true, "true", "pass", "aligned", 1]
end
