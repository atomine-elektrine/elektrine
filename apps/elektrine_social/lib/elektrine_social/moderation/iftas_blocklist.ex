defmodule ElektrineSocial.Moderation.IftasBlocklist do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias Elektrine.ActivityPub.Instance
  alias Elektrine.ActivityPub.MRF.SimplePolicy
  alias Elektrine.HTTP.SafeFetch
  alias Elektrine.Repo

  @source_name "IFTAS CARIAD"
  @source_marker "iftas:cariad"
  @default_max_body_bytes 2_000_000

  def sync(opts \\ []) do
    if Keyword.get(opts, :enabled, enabled?()) do
      url = Keyword.get(opts, :url, configured_url())

      if is_binary(url) and url != "" do
        with {:ok, body} <- fetch_url(url, opts),
             {:ok, result} <- apply_payload(body, opts) do
          {:ok, Map.put(result, :url, url)}
        end
      else
        {:ok, %{enabled: false, applied: 0, removed: 0, preserved: 0, skipped: 0}}
      end
    else
      {:ok, %{enabled: false, applied: 0, removed: 0, preserved: 0, skipped: 0}}
    end
  end

  def apply_payload(payload, opts \\ [])

  def apply_payload(payload, opts) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> apply_payload(decoded, opts)
      {:error, error} -> {:error, {:invalid_json, error}}
    end
  end

  def apply_payload(payload, opts) do
    entries = extract_entries(payload)

    if entries == [] do
      {:error, :empty_blocklist}
    else
      {:ok, apply_entries(entries, opts)}
    end
  end

  def apply_entries(entries, opts \\ []) when is_list(entries) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    remove_stale? = Keyword.get(opts, :remove_stale?, true)

    domains =
      entries
      |> Enum.map(&normalize_entry/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.domain)

    result =
      domains
      |> Enum.reduce(%{applied: 0, preserved: 0, skipped: 0}, fn entry, acc ->
        case upsert_entry(entry, now) do
          :applied -> Map.update!(acc, :applied, &(&1 + 1))
          :preserved -> Map.update!(acc, :preserved, &(&1 + 1))
          :skipped -> Map.update!(acc, :skipped, &(&1 + 1))
        end
      end)

    removed = if remove_stale?, do: remove_stale(domains), else: 0

    SimplePolicy.invalidate_cache()

    Map.put(result, :removed, removed)
  end

  def configured_url do
    config()
    |> Keyword.get(:url)
    |> case do
      url when is_binary(url) and url != "" -> url
      _ -> default_url(configured_threshold(), configured_api_key())
    end
  end

  def enabled?, do: Keyword.get(config(), :enabled, true)

  def configured_threshold, do: Keyword.get(config(), :threshold, 66)

  def configured_api_key, do: Keyword.get(config(), :api_key)

  defp fetch_url(url, opts) when is_binary(url) and url != "" do
    headers = [
      {"user-agent", "Elektrine/1.0 IFTASBlocklist (+#{ElektrineWeb.Endpoint.url()})"},
      {"accept", "application/json"}
    ]

    request = Finch.build(:get, url, headers)
    max_body_bytes = Keyword.get(opts, :max_body_bytes, @default_max_body_bytes)

    case SafeFetch.request(request, Elektrine.Finch,
           receive_timeout: 30_000,
           pool_timeout: 30_000,
           max_body_bytes: max_body_bytes
         ) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_url(_, _), do: {:error, :missing_url}

  defp extract_entries(%{"success" => true, "data" => %{"domains" => domains}})
       when is_list(domains),
       do: domains

  defp extract_entries(%{"data" => %{"domains" => domains}}) when is_list(domains), do: domains
  defp extract_entries(%{"domains" => domains}) when is_list(domains), do: domains
  defp extract_entries(domains) when is_list(domains), do: domains
  defp extract_entries(_), do: []

  defp normalize_entry(%{"domain" => domain} = entry) do
    normalize_domain(domain)
    |> case do
      nil -> nil
      domain -> %{domain: domain, severity: normalize_severity(entry["severity"])}
    end
  end

  defp normalize_entry(%{domain: domain} = entry) do
    normalize_domain(domain)
    |> case do
      nil -> nil
      domain -> %{domain: domain, severity: normalize_severity(Map.get(entry, :severity))}
    end
  end

  defp normalize_entry(domain) when is_binary(domain) do
    normalize_domain(domain)
    |> case do
      nil -> nil
      domain -> %{domain: domain, severity: "suspend"}
    end
  end

  defp normalize_entry(_), do: nil

  defp normalize_domain(domain) when is_binary(domain) do
    domain =
      domain
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/^https?:\/\//, "")
      |> String.split("/", parts: 2)
      |> hd()
      |> String.trim_trailing(".")

    if Regex.match?(
         ~r/^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?$/,
         domain
       ),
       do: domain,
       else: nil
  end

  defp normalize_domain(_), do: nil

  defp normalize_severity(severity) when is_binary(severity), do: String.downcase(severity)
  defp normalize_severity(_), do: "suspend"

  defp upsert_entry(entry, now) do
    attrs = policy_attrs(entry, now)

    case get_instance(entry.domain) do
      %Instance{} = instance -> update_instance(instance, attrs)
      nil -> insert_instance(attrs)
    end
  end

  defp update_instance(%Instance{blocked: true} = instance, attrs)
       when not is_nil(instance.blocked_by_id) do
    Logger.debug("Preserving manually blocked instance #{instance.domain} during IFTAS sync")

    if attrs.blocked, do: :preserved, else: :skipped
  end

  defp update_instance(%Instance{} = instance, attrs) do
    instance
    |> Instance.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, _} ->
        :applied

      {:error, changeset} ->
        Logger.warning(
          "Failed to apply IFTAS policy for #{instance.domain}: #{inspect(changeset.errors)}"
        )

        :skipped
    end
  end

  defp insert_instance(attrs) do
    %Instance{}
    |> Instance.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _} ->
        :applied

      {:error, changeset} ->
        Logger.warning(
          "Failed to insert IFTAS policy for #{attrs.domain}: #{inspect(changeset.errors)}"
        )

        :skipped
    end
  end

  defp policy_attrs(%{domain: domain, severity: severity}, now) do
    base = %{
      domain: domain,
      reason: "#{@source_name}: #{severity}",
      notes: "#{@source_marker}; threshold=#{configured_threshold()}; severity=#{severity}",
      policy_applied_at: now
    }

    if severity in ["suspend", "reject", "block", "blocked"] do
      Map.merge(base, %{
        blocked: true,
        silenced: false,
        federated_timeline_removal: false,
        blocked_at: now
      })
    else
      Map.merge(base, %{
        blocked: false,
        silenced: true,
        federated_timeline_removal: true,
        blocked_at: nil
      })
    end
  end

  defp remove_stale(current_entries) do
    current_domains = MapSet.new(current_entries, & &1.domain)

    Instance
    |> where([i], like(i.notes, ^"%#{@source_marker}%"))
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(current_domains, &1.domain))
    |> Enum.count(fn instance ->
      if iftas_managed?(instance) do
        clear_iftas_policy(instance)
      else
        false
      end
    end)
  end

  defp iftas_managed?(%Instance{} = instance) do
    is_binary(instance.notes) and String.contains?(instance.notes, @source_marker) and
      is_nil(instance.blocked_by_id) and is_nil(instance.policy_applied_by_id)
  end

  defp clear_iftas_policy(%Instance{} = instance) do
    attrs = %{
      blocked: false,
      silenced: false,
      federated_timeline_removal: false,
      reason: nil,
      notes: nil,
      blocked_at: nil,
      policy_applied_at: nil
    }

    case instance |> Instance.changeset(attrs) |> Repo.update() do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp get_instance(domain) do
    Instance
    |> where([i], fragment("lower(?)", i.domain) == ^domain)
    |> limit(1)
    |> Repo.one()
  end

  defp config, do: Application.get_env(:elektrine_social, :iftas_blocklist, [])

  defp default_url(_threshold, api_key) when not is_binary(api_key) or api_key == "", do: nil

  defp default_url(threshold, api_key) do
    "https://cariad.fedicheck.iftas.org/api/v1/denylist/domains/by-threshold?" <>
      URI.encode_query(%{
        threshold: threshold,
        api_key: api_key
      })
  end
end
