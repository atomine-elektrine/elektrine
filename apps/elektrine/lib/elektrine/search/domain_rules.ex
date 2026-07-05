defmodule Elektrine.Search.DomainRules do
  @moduledoc """
  Per-user domain rules for web search: block, lower, raise, or pin a domain
  across all searches. A rule matches its domain and every subdomain, so a
  rule on `example.com` also covers `docs.example.com`.
  """

  import Ecto.Query

  alias Elektrine.Repo
  alias Elektrine.Search.DomainRule

  # Relevance scale context: internal app results score ~0.7-1.1 and external
  # web results ~0.6 and below, so pins must clear 1.1 and the boost/penalty
  # moves a result across roughly half that band.
  @pin_relevance 5.0
  @raise_boost 0.35
  @lower_penalty 0.35
  @max_rules_per_user 500

  def list_rules(user_id) do
    DomainRule
    |> where(user_id: ^user_id)
    |> order_by(asc: :domain)
    |> Repo.all()
  end

  @doc "Returns the user's rules as a `%{\"domain\" => action}` map."
  def rules_map(nil), do: %{}

  def rules_map(user_id) do
    user_id
    |> list_rules()
    |> Map.new(&{&1.domain, &1.action})
  end

  def set_rule(user, domain, action) do
    if Repo.aggregate(where(DomainRule, user_id: ^user.id), :count) >= @max_rules_per_user do
      {:error, :rule_limit_reached}
    else
      %DomainRule{user_id: user.id}
      |> DomainRule.changeset(%{domain: domain, action: action})
      |> Repo.insert(
        on_conflict: {:replace, [:action, :updated_at]},
        conflict_target: [:user_id, :domain],
        returning: true
      )
    end
  end

  def remove_rule(user, domain) do
    domain = DomainRule.normalize_domain(domain)

    DomainRule
    |> where(user_id: ^user.id, domain: ^domain)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Re-ranks search-result maps (anything with `:url` and `:relevance` keys)
  according to a `rules_map/1`. Blocked domains are dropped entirely.
  """
  def apply_rules(results, rules) when rules == %{} or is_nil(rules), do: results

  def apply_rules(results, rules) do
    Enum.flat_map(results, fn result ->
      case rule_for(result, rules) do
        :block -> []
        :pin -> [Map.put(result, :relevance, @pin_relevance)]
        :raise -> [Map.update(result, :relevance, @raise_boost, &(&1 + @raise_boost))]
        :lower -> [Map.update(result, :relevance, -@lower_penalty, &(&1 - @lower_penalty))]
        nil -> [result]
      end
    end)
  end

  defp rule_for(%{url: url}, rules) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        host = DomainRule.normalize_domain(host)

        Enum.find_value(rules, fn {domain, action} ->
          if host == domain or String.ends_with?(host, "." <> domain), do: action
        end)

      _uri ->
        nil
    end
  end

  defp rule_for(_result, _rules), do: nil
end
