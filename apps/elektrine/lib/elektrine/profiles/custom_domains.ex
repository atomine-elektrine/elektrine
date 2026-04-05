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
            last_error: nil
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
    |> CustomDomain.changeset(%{
      status: @pending_status,
      last_checked_at: now,
      last_error: error_message
    })
    |> Repo.update()
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
