defmodule Elektrine.Email.HarakaAdmin do
  @moduledoc false

  alias Elektrine.Domains
  alias Elektrine.Email.DKIM
  alias Elektrine.EmailConfig
  alias Elektrine.RuntimeEnv

  @status_path "/status"
  @metrics_path "/metrics"
  @request_timeout 5_000

  def overview do
    domains = Domains.supported_email_domains()
    status = fetch_status()
    metrics = fetch_metrics()
    domain_diagnostics = Enum.map(domains, &domain_diagnostic/1)

    %{
      base_url: lookup_base_url(),
      send_base_url: EmailConfig.haraka_base_url(),
      api_key_configured: present?(lookup_api_key()),
      primary_domain: Domains.primary_email_domain(),
      supported_domains: domains,
      mx_host: DKIM.mx_host(),
      mx_priority: DKIM.mx_priority(),
      spf_value: DKIM.spf_value(),
      dmarc_value: DKIM.dmarc_value(),
      status_details: status,
      metrics: metrics,
      domain_diagnostics: domain_diagnostics,
      haraka_status: overall_status(status, metrics, domain_diagnostics)
    }
  end

  defp domain_diagnostic(domain) do
    case DKIM.fetch_domain(domain) do
      {:ok, fetched} ->
        %{
          domain: domain,
          status: :ok,
          selector: fetched.selector,
          host: fetched.host,
          value: fetched.value,
          public_key_present: present?(fetched.public_key),
          private_key_present: fetched.private_key_present,
          notes: fetched.notes
        }

      {:error, reason} ->
        %{
          domain: domain,
          status: :error,
          error: reason,
          host: nil,
          value: nil,
          selector: nil,
          public_key_present: false,
          private_key_present: false,
          notes: []
        }
    end
  end

  defp fetch_status do
    case request_json(lookup_base_url(), @status_path) do
      {:ok, %{"ok" => true} = payload} ->
        %{
          status: :ok,
          role: payload["role"],
          started_at: payload["started_at"],
          error: nil
        }

      {:ok, %{} = payload} ->
        %{
          status: :error,
          role: payload["role"],
          started_at: payload["started_at"],
          error: payload["error"] || "Haraka status endpoint returned an unexpected payload."
        }

      {:error, reason} ->
        %{status: :error, role: nil, started_at: nil, error: reason}
    end
  end

  defp fetch_metrics do
    case request_text(lookup_base_url(), @metrics_path) do
      {:ok, body} ->
        parsed = parse_prometheus_metrics(body)

        %{
          status: :ok,
          request_total: metric_value(parsed, "elektrine_http_api_requests_total"),
          auth_failures: metric_value(parsed, "elektrine_http_api_auth_failures_total"),
          rate_limited: metric_value(parsed, "elektrine_http_api_rate_limited_total"),
          sent_ok: metric_value(parsed, "elektrine_http_api_sent_ok_total"),
          sent_error: metric_value(parsed, "elektrine_http_api_sent_error_total"),
          dkim_sync_ok: metric_value(parsed, "elektrine_http_api_dkim_sync_ok_total"),
          dkim_sync_error: metric_value(parsed, "elektrine_http_api_dkim_sync_error_total"),
          dkim_delete_ok: metric_value(parsed, "elektrine_http_api_dkim_delete_ok_total"),
          dkim_delete_error: metric_value(parsed, "elektrine_http_api_dkim_delete_error_total"),
          uptime_seconds: metric_value(parsed, "elektrine_http_api_uptime_seconds"),
          error: nil
        }

      {:error, reason} ->
        %{
          status: :error,
          request_total: nil,
          auth_failures: nil,
          rate_limited: nil,
          sent_ok: nil,
          sent_error: nil,
          dkim_sync_ok: nil,
          dkim_sync_error: nil,
          dkim_delete_ok: nil,
          dkim_delete_error: nil,
          uptime_seconds: nil,
          error: reason
        }
    end
  end

  defp overall_status(status, metrics, domain_diagnostics) do
    cond do
      status.status == :ok and metrics.status == :ok ->
        :connected

      Enum.any?(domain_diagnostics, &(&1.status == :ok)) ->
        :connected

      status.status == :error or metrics.status == :error or
          Enum.any?(domain_diagnostics, &(&1.status == :error)) ->
        :error

      true ->
        :unknown
    end
  end

  defp request_json(base_url, path) do
    with {:ok, response_body} <- request(base_url, path),
         {:ok, payload} <- Jason.decode(response_body) do
      {:ok, payload}
    else
      {:error, _} = error -> error
      {:error, reason, _body} -> {:error, reason}
      _ -> {:error, "Haraka returned invalid JSON."}
    end
  end

  defp request_text(base_url, path) do
    request(base_url, path)
  end

  defp request(base_url, _path) when not is_binary(base_url) or base_url == "" do
    {:error, "Haraka base URL is not configured"}
  end

  defp request(base_url, path) do
    case http_client().request(
           :get,
           "#{String.trim_trailing(base_url, "/")}#{path}",
           request_headers(),
           "",
           receive_timeout: @request_timeout
         ) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error,
         "Haraka endpoint #{path} failed with status #{status}: #{normalize_error_body(body)}"}

      {:error, reason} ->
        {:error, "Haraka endpoint #{path} failed: #{inspect(reason)}"}
    end
  end

  defp request_headers do
    case lookup_api_key() do
      api_key when is_binary(api_key) and api_key != "" -> [{"x-api-key", api_key}]
      _ -> []
    end
  end

  defp http_client, do: EmailConfig.haraka_http_client()

  defp parse_prometheus_metrics(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      if String.starts_with?(line, "#") do
        acc
      else
        case String.split(line, ~r/\s+/, parts: 2, trim: true) do
          [name, value] -> Map.put(acc, name, parse_metric_number(value))
          _ -> acc
        end
      end
    end)
  end

  defp parse_prometheus_metrics(_), do: %{}

  defp parse_metric_number(value) do
    case Integer.parse(value) do
      {integer, ""} ->
        integer

      _ ->
        case Float.parse(value) do
          {float, ""} -> trunc(float)
          _ -> nil
        end
    end
  end

  defp metric_value(metrics, name), do: Map.get(metrics, name)

  defp normalize_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} when is_binary(error) -> error
      {:ok, %{"message" => message}} when is_binary(message) -> message
      _ -> String.trim(body)
    end
  end

  defp normalize_error_body(body), do: inspect(body)

  defp present?(value) when is_binary(value), do: Elektrine.Strings.present?(value)
  defp present?(_), do: false

  defp lookup_base_url do
    RuntimeEnv.app_config(:email, [])
    |> Keyword.get(:custom_domain_haraka_base_url, EmailConfig.haraka_base_url())
  end

  defp lookup_api_key do
    RuntimeEnv.app_config(:email, [])
    |> Keyword.get(:custom_domain_haraka_api_key, EmailConfig.haraka_api_key())
  end
end
