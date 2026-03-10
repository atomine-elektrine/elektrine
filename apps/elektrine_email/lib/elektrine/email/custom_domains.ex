defmodule Elektrine.Email.CustomDomains do
  @moduledoc """
  User-owned custom email domains with DNS-based verification.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Multi
  alias Elektrine.Accounts.User
  alias Elektrine.Email.CustomDomain
  alias Elektrine.Email.DKIM
  alias Elektrine.Repo

  @pending_status "pending"
  @verified_status "verified"
  @verification_label "_elektrine-verification"

  @type lookup_result :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  Behaviour for DNS record lookup during custom-domain verification.
  """
  @callback lookup_txt(String.t()) :: lookup_result
  @callback lookup_mx(String.t()) :: lookup_result

  defmodule DNSResolver do
    @moduledoc false
    @behaviour Elektrine.Email.CustomDomains

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

    @impl true
    def lookup_mx(host) when is_binary(host) do
      host
      |> String.to_charlist()
      |> :inet_res.lookup(:in, :mx, timeout: 5_000)
      |> Enum.map(&normalize_mx_record/1)
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

    defp normalize_mx_record({priority, exchange}) when is_integer(priority) do
      normalize_mx_host(exchange)
    end

    defp normalize_mx_record(exchange), do: normalize_mx_host(exchange)

    defp normalize_mx_host(host) when is_binary(host) do
      host
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.downcase()
    end

    defp normalize_mx_host(host) when is_list(host) do
      if Enum.all?(host, &is_integer/1) do
        host
        |> to_string()
        |> normalize_mx_host()
      else
        host
        |> Enum.map_join("", &normalize_mx_host/1)
        |> normalize_mx_host()
      end
    end

    defp normalize_mx_host(host), do: host |> to_string() |> normalize_mx_host()
  end

  def list_user_custom_domains(user_id) when is_integer(user_id) do
    CustomDomain
    |> where(user_id: ^user_id)
    |> order_by([d], asc: d.domain)
    |> Repo.all()
    |> Enum.map(&hydrate_custom_domain/1)
  end

  def list_user_custom_domains(_), do: []

  def get_custom_domain(id, user_id) when is_integer(id) and is_integer(user_id) do
    CustomDomain
    |> where(id: ^id, user_id: ^user_id)
    |> Repo.one()
    |> hydrate_custom_domain()
  end

  def get_custom_domain(_, _), do: nil

  def get_verified_custom_domain(domain) when is_binary(domain) do
    normalized_domain = normalize_domain(domain)

    CustomDomain
    |> where(
      [d],
      fragment("lower(?)", d.domain) == ^normalized_domain and d.status == ^@verified_status
    )
    |> preload(:user)
    |> Repo.one()
    |> hydrate_custom_domain()
  end

  def get_verified_custom_domain(_), do: nil

  def verified_domains do
    CustomDomain
    |> where(status: ^@verified_status)
    |> select([d], d.domain)
    |> Repo.all()
    |> Enum.map(&String.downcase/1)
  end

  def verified_domains_for_user(user_id) when is_integer(user_id) do
    CustomDomain
    |> where(user_id: ^user_id, status: ^@verified_status)
    |> select([d], d.domain)
    |> Repo.all()
    |> Enum.map(&String.downcase/1)
  end

  def verified_domains_for_user(_), do: []

  def available_domains_for_user(%User{id: user_id}), do: available_domains_for_user(user_id)

  def available_domains_for_user(user_id) when is_integer(user_id) do
    (Elektrine.Domains.supported_email_domains() ++ verified_domains_for_user(user_id))
    |> normalize_domains()
  end

  def available_domains_for_user(_), do: Elektrine.Domains.supported_email_domains()

  def receiving_domains do
    (Elektrine.Domains.supported_email_domains() ++ verified_domains()) |> normalize_domains()
  end

  def receiving_domain?(domain) when is_binary(domain) do
    normalize_domain(domain) in receiving_domains()
  end

  def receiving_domain?(_), do: false

  def user_can_use_domain?(%User{id: user_id}, domain), do: user_can_use_domain?(user_id, domain)

  def user_can_use_domain?(user_id, domain) when is_integer(user_id) and is_binary(domain) do
    normalize_domain(domain) in available_domains_for_user(user_id)
  end

  def user_can_use_domain?(_, _), do: false

  def create_custom_domain(%User{id: user_id}, attrs), do: create_custom_domain(user_id, attrs)

  def create_custom_domain(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    key_material = DKIM.generate_domain_key_material()

    %CustomDomain{}
    |> CustomDomain.changeset(%{
      domain: attrs[:domain] || attrs["domain"],
      verification_token: generate_verification_token(),
      dkim_selector: key_material.selector,
      dkim_public_key: key_material.public_key,
      dkim_private_key: key_material.private_key,
      status: @pending_status,
      user_id: user_id
    })
    |> Repo.insert()
    |> case do
      {:ok, custom_domain} -> {:ok, maybe_sync_custom_domain_dkim(custom_domain)}
      error -> error
    end
  end

  def sync_custom_domain_dkim(%CustomDomain{} = custom_domain) do
    custom_domain
    |> hydrate_custom_domain()
    |> then(fn hydrated -> {:ok, sync_custom_domain_dkim_now(hydrated)} end)
  end

  def dns_records_for_custom_domain(%CustomDomain{} = custom_domain) do
    custom_domain = hydrate_custom_domain(custom_domain)

    DKIM.dns_records_for_custom_domain(
      custom_domain,
      verification_host(custom_domain),
      verification_value(custom_domain)
    )
  end

  def verify_custom_domain(%CustomDomain{} = custom_domain) do
    custom_domain =
      custom_domain
      |> hydrate_custom_domain()
      |> maybe_sync_custom_domain_dkim()

    expected_value = verification_value(custom_domain)
    verification_host = verification_host(custom_domain)
    expected_mx_host = DKIM.mx_host() |> normalize_domain()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case dns_resolver().lookup_txt(verification_host) do
      {:ok, records} ->
        if expected_value in Enum.map(records, &normalize_txt_value/1) do
          case lookup_mx(verify_domain_host(custom_domain)) do
            {:ok, mx_records} ->
              if expected_mx_host in Enum.map(mx_records, &normalize_mx_value/1) do
                custom_domain
                |> Ecto.Changeset.change(%{
                  status: @verified_status,
                  verified_at: custom_domain.verified_at || now,
                  last_checked_at: now,
                  last_error: nil
                })
                |> Repo.update()
              else
                persist_verification_failure(
                  custom_domain,
                  now,
                  "Inbound MX record not found: expected #{expected_mx_host}"
                )
              end

            {:error, reason} ->
              persist_verification_failure(
                custom_domain,
                now,
                "MX lookup failed: #{inspect(reason)}"
              )
          end
        else
          persist_verification_failure(custom_domain, now, "Verification TXT record not found")
        end

      {:error, reason} ->
        persist_verification_failure(custom_domain, now, "DNS lookup failed: #{inspect(reason)}")
    end
  end

  def delete_custom_domain(%CustomDomain{} = custom_domain) do
    case DKIM.delete_custom_domain(custom_domain) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to remove DKIM material for #{custom_domain.domain}: #{reason}")
    end

    Multi.new()
    |> Multi.run(:reset_preferred_domain, fn repo, _changes ->
      case repo.get(User, custom_domain.user_id) do
        %User{} = user ->
          if String.downcase(user.preferred_email_domain || "") ==
               String.downcase(custom_domain.domain) do
            user
            |> Ecto.Changeset.change(
              preferred_email_domain: Elektrine.Domains.default_user_handle_domain()
            )
            |> repo.update()
          else
            {:ok, user}
          end

        nil ->
          {:ok, nil}
      end
    end)
    |> Multi.delete(:custom_domain, custom_domain)
    |> Repo.transaction()
    |> case do
      {:ok, %{custom_domain: deleted_custom_domain}} -> {:ok, deleted_custom_domain}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def verification_host(%CustomDomain{domain: domain}) when is_binary(domain) do
    verification_host(domain)
  end

  def verification_host(domain) when is_binary(domain) do
    "#{@verification_label}.#{normalize_domain(domain)}"
  end

  def verification_value(%CustomDomain{verification_token: token}) when is_binary(token) do
    verification_value(token)
  end

  def verification_value(token) when is_binary(token) do
    "elektrine-site-verification=#{token}"
  end

  defp hydrate_custom_domain(nil), do: nil

  defp hydrate_custom_domain(%CustomDomain{} = custom_domain) do
    if present?(custom_domain.dkim_selector) and present?(custom_domain.dkim_public_key) and
         present?(custom_domain.dkim_private_key) do
      custom_domain
    else
      key_material = DKIM.generate_domain_key_material()

      custom_domain
      |> Ecto.Changeset.change(%{
        dkim_selector: key_material.selector,
        dkim_public_key: key_material.public_key,
        dkim_private_key: key_material.private_key,
        dkim_synced_at: nil,
        dkim_last_error: custom_domain.dkim_last_error
      })
      |> Repo.update()
      |> case do
        {:ok, updated_custom_domain} -> updated_custom_domain
        {:error, _changeset} -> custom_domain
      end
    end
  end

  defp maybe_sync_custom_domain_dkim(%CustomDomain{} = custom_domain) do
    if custom_domain.dkim_synced_at && !present?(custom_domain.dkim_last_error) do
      custom_domain
    else
      sync_custom_domain_dkim_now(custom_domain)
    end
  end

  defp sync_custom_domain_dkim_now(%CustomDomain{} = custom_domain) do
    case DKIM.sync_custom_domain(custom_domain) do
      :ok ->
        custom_domain
        |> Ecto.Changeset.change(%{
          dkim_synced_at: DateTime.utc_now() |> DateTime.truncate(:second),
          dkim_last_error: nil
        })
        |> Repo.update()
        |> case do
          {:ok, updated_custom_domain} -> updated_custom_domain
          {:error, _changeset} -> custom_domain
        end

      {:error, reason} ->
        custom_domain
        |> Ecto.Changeset.change(%{
          dkim_synced_at: nil,
          dkim_last_error: truncate_error(reason)
        })
        |> Repo.update()
        |> case do
          {:ok, updated_custom_domain} -> updated_custom_domain
          {:error, _changeset} -> custom_domain
        end
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp truncate_error(value, max_length \\ 255) do
    value
    |> to_string()
    |> String.trim()
    |> String.slice(0, max_length)
  end

  defp maybe_reset_pending_status(changeset) do
    current_status = Ecto.Changeset.get_field(changeset, :status)

    if current_status == @verified_status do
      changeset
    else
      Ecto.Changeset.put_change(changeset, :status, @pending_status)
    end
  end

  defp persist_verification_failure(custom_domain, now, error_message) do
    custom_domain
    |> Ecto.Changeset.change(%{
      last_checked_at: now,
      last_error: truncate_error(error_message)
    })
    |> maybe_reset_pending_status()
    |> Repo.update()
  end

  defp dns_resolver do
    Application.get_env(:elektrine, :custom_domain_txt_resolver, DNSResolver)
  end

  defp lookup_mx(host) do
    resolver = dns_resolver()

    if function_exported?(resolver, :lookup_mx, 1) do
      resolver.lookup_mx(host)
    else
      DNSResolver.lookup_mx(host)
    end
  end

  defp verify_domain_host(%CustomDomain{domain: domain}), do: domain

  defp generate_verification_token do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp normalize_domain(domain) do
    domain
    |> String.trim()
    |> String.trim_leading(".")
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp normalize_domains(domains) do
    domains
    |> Enum.map(&normalize_domain/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_txt_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_txt_value(value), do: value |> to_string() |> String.trim()

  defp normalize_mx_value(value) when is_binary(value), do: normalize_domain(value)
  defp normalize_mx_value(value), do: value |> to_string() |> normalize_domain()
end
