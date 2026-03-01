defmodule Elektrine.Messaging.Federation.PeerPolicies do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.Messaging.FederationPeerPolicy
  alias Elektrine.Repo

  def apply_runtime_policies(configured_peers) when is_list(configured_peers) do
    policy_overrides = runtime_policy_overrides()

    Enum.map(configured_peers, fn peer ->
      apply_runtime_policy(peer, Map.get(policy_overrides, String.downcase(peer.domain)))
    end)
  end

  def apply_runtime_policies(_), do: []

  def list_peer_controls(configured_peers) when is_list(configured_peers) do
    configured_by_domain = Map.new(configured_peers, &{String.downcase(&1.domain), &1})
    policy_overrides = runtime_policy_overrides()
    users_by_id = users_by_id_for_policies(policy_overrides)

    configured_by_domain
    |> Map.keys()
    |> Enum.concat(Map.keys(policy_overrides))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn domain ->
      configured_peer = Map.get(configured_by_domain, domain)
      policy = Map.get(policy_overrides, domain)
      effective_peer = apply_runtime_policy(configured_peer, policy)

      %{
        domain: domain,
        configured: not is_nil(configured_peer),
        base_url: if(is_map(configured_peer), do: configured_peer.base_url, else: nil),
        blocked: if(is_map(policy), do: policy.blocked == true, else: false),
        reason: if(is_map(policy), do: policy.reason, else: nil),
        allow_incoming_override: if(is_map(policy), do: policy.allow_incoming, else: nil),
        allow_outgoing_override: if(is_map(policy), do: policy.allow_outgoing, else: nil),
        effective_allow_incoming:
          if(is_map(effective_peer), do: effective_peer.allow_incoming == true, else: false),
        effective_allow_outgoing:
          if(is_map(effective_peer), do: effective_peer.allow_outgoing == true, else: false),
        updated_at: if(is_map(policy), do: policy.updated_at, else: nil),
        updated_by: if(is_map(policy), do: Map.get(users_by_id, policy.updated_by_id), else: nil)
      }
    end)
  end

  def list_peer_controls(_), do: []

  def upsert_peer_policy(domain, attrs, updated_by_id \\ nil) when is_map(attrs) do
    with {:ok, normalized_domain} <- normalize_peer_domain(domain) do
      policy =
        Repo.get_by(FederationPeerPolicy, domain: normalized_domain) || %FederationPeerPolicy{}

      attrs =
        attrs
        |> normalize_peer_policy_attrs()
        |> Map.put(:domain, normalized_domain)
        |> maybe_put_updated_by(updated_by_id)

      policy
      |> FederationPeerPolicy.changeset(attrs)
      |> Repo.insert_or_update()
    end
  end

  def clear_peer_policy(domain) do
    with {:ok, normalized_domain} <- normalize_peer_domain(domain) do
      case Repo.get_by(FederationPeerPolicy, domain: normalized_domain) do
        nil -> {:ok, :not_found}
        policy -> Repo.delete(policy)
      end
    end
  end

  def block_peer_domain(domain, reason \\ nil, updated_by_id \\ nil) do
    attrs = %{
      blocked: true,
      allow_incoming: false,
      allow_outgoing: false,
      reason: normalize_reason(reason)
    }

    upsert_peer_policy(domain, attrs, updated_by_id)
  end

  def unblock_peer_domain(domain, updated_by_id \\ nil) do
    attrs = %{blocked: false, allow_incoming: nil, allow_outgoing: nil, reason: nil}
    upsert_peer_policy(domain, attrs, updated_by_id)
  end

  defp runtime_policy_overrides do
    from(p in FederationPeerPolicy, order_by: [asc: p.domain])
    |> Repo.all()
    |> Map.new(fn policy -> {String.downcase(policy.domain), policy} end)
  rescue
    _ ->
      %{}
  end

  defp users_by_id_for_policies(policy_overrides) when is_map(policy_overrides) do
    user_ids =
      policy_overrides
      |> Map.values()
      |> Enum.map(& &1.updated_by_id)
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    if user_ids == [] do
      %{}
    else
      try do
        from(u in User, where: u.id in ^user_ids, select: {u.id, u})
        |> Repo.all()
        |> Map.new()
      rescue
        _ ->
          %{}
      end
    end
  end

  defp users_by_id_for_policies(_), do: %{}

  defp apply_runtime_policy(nil, _policy), do: nil
  defp apply_runtime_policy(peer, nil) when is_map(peer), do: peer

  defp apply_runtime_policy(peer, policy) when is_map(peer) and is_map(policy) do
    blocked? = policy.blocked == true

    allow_incoming =
      cond do
        blocked? -> false
        is_boolean(policy.allow_incoming) -> policy.allow_incoming
        true -> peer.allow_incoming
      end

    allow_outgoing =
      cond do
        blocked? -> false
        is_boolean(policy.allow_outgoing) -> policy.allow_outgoing
        true -> peer.allow_outgoing
      end

    %{peer | allow_incoming: allow_incoming, allow_outgoing: allow_outgoing}
  end

  defp apply_runtime_policy(peer, _policy), do: peer

  defp normalize_peer_policy_attrs(attrs) when is_map(attrs) do
    %{
      allow_incoming:
        normalize_optional_boolean(value_from(attrs, :allow_incoming, :__missing__), :__missing__),
      allow_outgoing:
        normalize_optional_boolean(value_from(attrs, :allow_outgoing, :__missing__), :__missing__),
      blocked:
        normalize_optional_boolean(value_from(attrs, :blocked, :__missing__), :__missing__),
      reason: normalize_reason(value_from(attrs, :reason, :__missing__))
    }
    |> Enum.reject(fn {_key, value} -> value == :__missing__ end)
    |> Map.new()
  end

  defp normalize_peer_policy_attrs(_), do: %{}

  defp maybe_put_updated_by(attrs, updated_by_id)
       when is_map(attrs) and is_integer(updated_by_id) do
    Map.put(attrs, :updated_by_id, updated_by_id)
  end

  defp maybe_put_updated_by(attrs, _updated_by_id), do: attrs

  defp normalize_peer_domain(domain) when is_binary(domain) do
    normalized =
      domain
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/^https?:\/\//, "")
      |> String.split("/", parts: 2)
      |> List.first()
      |> to_string()
      |> String.trim(".")

    if normalized == "" do
      {:error, :invalid_domain}
    else
      {:ok, normalized}
    end
  end

  defp normalize_peer_domain(_), do: {:error, :invalid_domain}

  defp normalize_optional_boolean(:__missing__, missing), do: missing
  defp normalize_optional_boolean(nil, _missing), do: nil
  defp normalize_optional_boolean(true, _missing), do: true
  defp normalize_optional_boolean(false, _missing), do: false
  defp normalize_optional_boolean("true", _missing), do: true
  defp normalize_optional_boolean("false", _missing), do: false
  defp normalize_optional_boolean("1", _missing), do: true
  defp normalize_optional_boolean("0", _missing), do: false
  defp normalize_optional_boolean("inherit", _missing), do: nil
  defp normalize_optional_boolean("", _missing), do: nil
  defp normalize_optional_boolean(value, missing) when value == missing, do: missing
  defp normalize_optional_boolean(_value, _missing), do: nil

  defp normalize_reason(:__missing__), do: :__missing__

  defp normalize_reason(reason) when is_binary(reason) do
    trimmed = String.trim(reason)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_reason(nil), do: nil
  defp normalize_reason(_), do: nil

  defp value_from(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
