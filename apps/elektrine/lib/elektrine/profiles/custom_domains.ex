defmodule Elektrine.Profiles.CustomDomains do
  @moduledoc """
  User-owned custom profile domains with TXT-based verification.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.Profiles.CustomDomain
  alias Elektrine.Repo

  @pending_status "pending"
  @verified_status "verified"
  @verification_label "_elektrine-profile"

  # A verified domain that starts failing re-verification is kept verified for
  # this grace window before demotion, so transient DNS hiccups don't take a
  # working profile domain offline.
  @verification_grace_period_seconds 72 * 60 * 60

  @type lookup_result :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  Behaviour for DNS TXT lookups during profile-domain verification.
  """
  @callback lookup_txt(String.t()) :: lookup_result

  defmodule DNSResolver do
    @moduledoc false
    @behaviour Elektrine.Profiles.CustomDomains

    @impl true
    def lookup_txt(host) when is_binary(host) do
      host
      |> String.to_charlist()
      |> :inet_res.lookup(:in, :txt, timeout: 5_000)
      |> Enum.map(&normalize_txt_record/1)
      |> then(&{:ok, &1})
    rescue
      error -> {:error, error}
    end

    defp normalize_txt_record(record) when is_binary(record), do: record

    defp normalize_txt_record(record) when is_list(record) do
      if Enum.all?(record, &is_integer/1) do
        to_string(record)
      else
        Enum.map_join(record, "", &normalize_txt_record/1)
      end
    end

    defp normalize_txt_record(record), do: to_string(record)
  end

  def list_user_custom_domains(user_id) when is_integer(user_id) do
    CustomDomain
    |> where(user_id: ^user_id)
    |> order_by([d], asc: d.domain)
    |> Repo.all()
  end

  def list_user_custom_domains(_), do: []

  @doc """
  Lists profile custom domains for the admin console, across all users.

  Mirrors `Elektrine.Email.CustomDomains.list_custom_domains_admin/4`: supports a
  domain/owner search, a status filter (all/verified/pending/attention), and
  pagination. Returns `{domains, total_count}` with the owning user preloaded.
  """
  def list_custom_domains_admin(
        search_query \\ "",
        status_filter \\ "all",
        page \\ 1,
        per_page \\ 20
      ) do
    normalized_search = normalize_admin_search(search_query)
    normalized_status = normalize_admin_status_filter(status_filter)
    safe_page = max(page, 1)
    safe_per_page = max(per_page, 1)

    base_query =
      CustomDomain
      |> join(:left, [d], u in assoc(d, :user))
      |> maybe_filter_admin_status(normalized_status)
      |> maybe_search_admin(normalized_search)

    total_count = Repo.aggregate(base_query, :count, :id)

    domains =
      base_query
      |> order_by([d, _u], desc: d.inserted_at, asc: d.domain)
      |> preload([_d, u], user: u)
      |> limit(^safe_per_page)
      |> offset(^((safe_page - 1) * safe_per_page))
      |> Repo.all()

    {domains, total_count}
  end

  @doc """
  Aggregate counts of profile custom domains for the admin overview.
  """
  def custom_domain_admin_stats do
    total = Repo.aggregate(CustomDomain, :count, :id)

    verified =
      Repo.aggregate(from(d in CustomDomain, where: d.status == ^@verified_status), :count, :id)

    pending =
      Repo.aggregate(from(d in CustomDomain, where: d.status == ^@pending_status), :count, :id)

    attention =
      Repo.aggregate(
        from(d in CustomDomain,
          where: (not is_nil(d.last_error) and d.last_error != "") or not is_nil(d.failing_since)
        ),
        :count,
        :id
      )

    %{total: total, verified: verified, pending: pending, attention: attention}
  end

  defp maybe_search_admin(query, ""), do: query

  defp maybe_search_admin(query, search_query) do
    search_pattern = "%#{search_query}%"

    from([d, u] in query,
      where:
        ilike(d.domain, ^search_pattern) or
          ilike(fragment("coalesce(?, '')", u.username), ^search_pattern)
    )
  end

  defp maybe_filter_admin_status(query, "all"), do: query

  defp maybe_filter_admin_status(query, "attention") do
    from([d, _u] in query,
      where: (not is_nil(d.last_error) and d.last_error != "") or not is_nil(d.failing_since)
    )
  end

  defp maybe_filter_admin_status(query, status) do
    from([d, _u] in query, where: d.status == ^status)
  end

  defp normalize_admin_search(search_query) when is_binary(search_query),
    do: String.trim(search_query)

  defp normalize_admin_search(_), do: ""

  defp normalize_admin_status_filter(status_filter)
       when status_filter in ["all", "pending", "verified", "attention"],
       do: status_filter

  defp normalize_admin_status_filter(_), do: "all"

  @doc """
  Returns custom domains due for a periodic DNS re-verification, oldest check
  first so the stalest records are revisited before newer ones.
  """
  def list_custom_domains_for_recheck(limit \\ 500) when is_integer(limit) do
    CustomDomain
    |> order_by([d], asc_nulls_first: d.last_checked_at)
    |> limit(^max(limit, 0))
    |> Repo.all()
  end

  def get_custom_domain(id, user_id) when is_integer(id) and is_integer(user_id) do
    CustomDomain
    |> where(id: ^id, user_id: ^user_id)
    |> Repo.one()
  end

  def get_custom_domain(_, _), do: nil

  def get_verified_custom_domain(domain) when is_binary(domain) do
    normalized_domain = normalize_host(domain)

    CustomDomain
    |> where(
      [d],
      fragment("lower(?)", d.domain) == ^normalized_domain and d.status == ^@verified_status
    )
    |> preload(:user)
    |> Repo.one()
  end

  def get_verified_custom_domain(_), do: nil

  def get_verified_custom_domain_for_host(host) when is_binary(host) do
    normalized_host = normalize_host(host)

    cond do
      normalized_host == "" ->
        nil

      String.starts_with?(normalized_host, "www.") ->
        get_verified_custom_domain(String.trim_leading(normalized_host, "www."))

      true ->
        get_verified_custom_domain(normalized_host)
    end
  end

  def get_verified_custom_domain_for_host(_), do: nil

  def verified_domains_for_user(%User{id: user_id}), do: verified_domains_for_user(user_id)

  def verified_domains_for_user(user_id) when is_integer(user_id) do
    CustomDomain
    |> where(user_id: ^user_id, status: ^@verified_status)
    |> order_by([d], asc: d.domain)
    |> Repo.all()
  end

  def verified_domains_for_user(_), do: []

  def preferred_verified_domain_for_user(%User{id: user_id}),
    do: preferred_verified_domain_for_user(user_id)

  def preferred_verified_domain_for_user(user_id) when is_integer(user_id) do
    case verified_domains_for_user(user_id) do
      [%CustomDomain{} = custom_domain] -> custom_domain
      _ -> nil
    end
  end

  def preferred_verified_domain_for_user(_), do: nil

  def create_custom_domain(%User{id: user_id}, attrs), do: create_custom_domain(user_id, attrs)

  def create_custom_domain(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    %CustomDomain{}
    |> CustomDomain.changeset(%{
      domain: attrs[:domain] || attrs["domain"],
      verification_token: generate_verification_token(),
      status: @pending_status,
      user_id: user_id
    })
    |> Repo.insert()
  end

  def verify_custom_domain(%CustomDomain{} = custom_domain) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expected_value = verification_value(custom_domain)
    verification_host = verification_host(custom_domain)

    case lookup_txt(verification_host) do
      {:ok, values} ->
        if expected_value in values do
          custom_domain
          |> CustomDomain.changeset(%{
            status: @verified_status,
            verified_at: custom_domain.verified_at || now,
            last_checked_at: now,
            last_error: nil,
            failing_since: nil
          })
          |> Repo.update()
        else
          persist_verification_failure(custom_domain, now, "Verification TXT record not found")
        end

      {:error, reason} ->
        persist_verification_failure(custom_domain, now, "DNS lookup failed: #{inspect(reason)}")
    end
  end

  def delete_custom_domain(%CustomDomain{} = custom_domain) do
    Repo.delete(custom_domain)
  end

  def verification_host(%CustomDomain{domain: domain}) when is_binary(domain) do
    "#{@verification_label}.#{domain}"
  end

  def verification_host(_), do: nil

  def verification_value(%CustomDomain{verification_token: token}) when is_binary(token) do
    "elektrine-profile-verification=#{token}"
  end

  def verification_value(_), do: nil

  def dns_records_for_custom_domain(%CustomDomain{} = custom_domain) do
    [
      %{
        type: "TXT",
        host: verification_host(custom_domain),
        value: verification_value(custom_domain),
        label: "Ownership verification",
        priority: nil
      }
      | routing_dns_records_for_custom_domain(custom_domain.domain)
    ]
  end

  defp persist_verification_failure(custom_domain, now, error_message) do
    custom_domain
    |> CustomDomain.changeset(verification_failure_attrs(custom_domain, now, error_message))
    |> Repo.update()
  end

  # Pending domains simply record the failure. Verified domains stay verified
  # until they have been failing continuously past the grace window, at which
  # point they are demoted back to pending.
  defp verification_failure_attrs(custom_domain, now, error_message) do
    base = %{last_checked_at: now, last_error: error_message}

    if custom_domain.status == @verified_status do
      failing_since = custom_domain.failing_since || now

      if DateTime.diff(now, failing_since, :second) >= @verification_grace_period_seconds do
        Map.merge(base, %{status: @pending_status, verified_at: nil, failing_since: nil})
      else
        Map.put(base, :failing_since, failing_since)
      end
    else
      Map.merge(base, %{status: @pending_status, failing_since: nil})
    end
  end

  defp generate_verification_token do
    24
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp lookup_txt(host) do
    txt_resolver().lookup_txt(host)
  end

  defp txt_resolver do
    Application.get_env(:elektrine, :profile_custom_domain_txt_resolver, DNSResolver)
  end

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp routing_dns_records_for_custom_domain(domain) do
    [
      %{
        type: "ALIAS",
        host: domain,
        value: Elektrine.Domains.profile_custom_domain_routing_target(),
        label: "Stable routing target for the root domain using apex alias flattening.",
        priority: nil
      }
    ] ++
      [
        %{
          type: "CNAME",
          host: "www.#{domain}",
          value: domain,
          label: "Optional www redirect target",
          priority: nil
        }
      ]
  end
end
