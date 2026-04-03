defmodule Elektrine.Email.DKIM do
  @moduledoc """
  DKIM helpers for managed custom email domains.
  """

  alias Elektrine.Email.CustomDomain

  @default_selector "default"
  @default_mx_priority 10
  @default_dmarc_policy "quarantine"
  @default_dmarc_alignment "s"
  @default_timeout_ms 10_000
  @default_haraka_path "/api/v1/dkim/domains"

  @type dns_record :: %{
          label: String.t(),
          type: String.t(),
          host: String.t(),
          value: String.t(),
          priority: integer() | nil
        }

  defmodule FinchClient do
    @moduledoc false

    def request(method, url, headers, body, opts) do
      method
      |> Finch.build(url, headers, body)
      |> Finch.request(Elektrine.Finch, opts)
    end
  end

  @spec generate_domain_key_material() :: %{
          selector: String.t(),
          public_key: String.t(),
          private_key: String.t()
        }
  def generate_domain_key_material do
    selector = configured_selector()
    {public_key, private_key} = generate_key_pair()

    %{
      selector: selector,
      public_key: public_key,
      private_key: private_key
    }
  end

  @spec sync_custom_domain(CustomDomain.t()) :: :ok | {:error, String.t()}
  def sync_custom_domain(%CustomDomain{} = custom_domain) do
    with :ok <- ensure_sync_ready(custom_domain),
         {:ok, request_config} <- request_config(custom_domain.domain) do
      body =
        Jason.encode!(%{
          selector: custom_domain.dkim_selector,
          private_key: custom_domain.dkim_private_key
        })

      case http_client().request(
             :put,
             request_config.url,
             request_config.headers,
             body,
             receive_timeout: request_config.timeout
           ) do
        {:ok, %Finch.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Finch.Response{status: status, body: response_body}} ->
          {:error,
           "Haraka DKIM sync failed with status #{status}: #{normalize_error_body(response_body)}"}

        {:error, reason} ->
          {:error, "Haraka DKIM sync failed: #{inspect(reason)}"}
      end
    end
  end

  @spec sync_domain(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def sync_domain(domain, selector, private_key)
      when is_binary(domain) and is_binary(selector) and is_binary(private_key) do
    with true <- Elektrine.Strings.present?(selector) and Elektrine.Strings.present?(private_key),
         {:ok, request_config} <- request_config(domain) do
      body = Jason.encode!(%{selector: selector, private_key: private_key})

      case http_client().request(
             :put,
             request_config.url,
             request_config.headers,
             body,
             receive_timeout: request_config.timeout
           ) do
        {:ok, %Finch.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Finch.Response{status: status, body: response_body}} ->
          {:error,
           "Haraka DKIM sync failed with status #{status}: #{normalize_error_body(response_body)}"}

        {:error, reason} ->
          {:error, "Haraka DKIM sync failed: #{inspect(reason)}"}
      end
    else
      false -> {:error, "DKIM key material is missing"}
      error -> error
    end
  end

  @spec delete_custom_domain(CustomDomain.t()) :: :ok | {:error, String.t()}
  def delete_custom_domain(%CustomDomain{} = custom_domain) do
    with {:ok, request_config} <- request_config(custom_domain.domain) do
      case http_client().request(
             :delete,
             request_config.url,
             request_config.headers,
             "",
             receive_timeout: request_config.timeout
           ) do
        {:ok, %Finch.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Finch.Response{status: 404}} ->
          :ok

        {:ok, %Finch.Response{status: status, body: response_body}} ->
          {:error,
           "Haraka DKIM delete failed with status #{status}: #{normalize_error_body(response_body)}"}

        {:error, reason} ->
          {:error, "Haraka DKIM delete failed: #{inspect(reason)}"}
      end
    end
  end

  @spec dns_records_for_custom_domain(CustomDomain.t(), String.t(), String.t()) :: [dns_record()]
  def dns_records_for_custom_domain(
        %CustomDomain{} = custom_domain,
        verification_host,
        verification_value
      ) do
    [
      %{
        label: "Ownership TXT",
        type: "TXT",
        host: verification_host,
        value: verification_value,
        priority: nil
      },
      %{
        label: "Inbound MX",
        type: "MX",
        host: custom_domain.domain,
        value: mx_host(),
        priority: mx_priority()
      },
      %{
        label: "SPF",
        type: "TXT",
        host: custom_domain.domain,
        value: spf_value(),
        priority: nil
      },
      %{
        label: "DKIM",
        type: "TXT",
        host: "#{custom_domain.dkim_selector}._domainkey.#{custom_domain.domain}",
        value: dkim_value(custom_domain),
        priority: nil
      },
      %{
        label: "DMARC",
        type: "TXT",
        host: "_dmarc.#{custom_domain.domain}",
        value: dmarc_value(),
        priority: nil
      }
    ]
  end

  @spec dkim_value(CustomDomain.t()) :: String.t()
  def dkim_value(%CustomDomain{} = custom_domain) do
    "v=DKIM1; k=rsa; p=#{public_key_dns_value(custom_domain.dkim_public_key)}"
  end

  @spec mx_host() :: String.t()
  def mx_host do
    email_config()
    |> Keyword.get(:custom_domain_mx_host, default_mail_host())
  end

  @spec mx_priority() :: integer()
  def mx_priority do
    email_config()
    |> Keyword.get(:custom_domain_mx_priority, @default_mx_priority)
  end

  @spec spf_value() :: String.t()
  def spf_value do
    case email_config()[:custom_domain_spf_include] do
      value when is_binary(value) ->
        if Elektrine.Strings.present?(value),
          do: "v=spf1 include:#{value} ~all",
          else: "v=spf1 mx ~all"

      _ ->
        "v=spf1 mx ~all"
    end
  end

  @spec dmarc_value() :: String.t()
  def dmarc_value do
    email_cfg = email_config()
    policy = Keyword.get(email_cfg, :custom_domain_dmarc_policy, @default_dmarc_policy)
    rua = Keyword.get(email_cfg, :custom_domain_dmarc_rua)
    adkim = Keyword.get(email_cfg, :custom_domain_dmarc_adkim, @default_dmarc_alignment)
    aspf = Keyword.get(email_cfg, :custom_domain_dmarc_aspf, @default_dmarc_alignment)

    [
      "v=DMARC1",
      "p=#{policy}",
      "adkim=#{adkim}",
      "aspf=#{aspf}",
      dmarc_rua_fragment(rua)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  @spec public_key_dns_value(String.t()) :: String.t()
  def public_key_dns_value(public_key_pem) when is_binary(public_key_pem) do
    public_key_pem
    |> String.replace(~r/-----BEGIN PUBLIC KEY-----/, "")
    |> String.replace(~r/-----END PUBLIC KEY-----/, "")
    |> String.replace(~r/\s+/, "")
  end

  def public_key_dns_value(_), do: ""

  defp ensure_sync_ready(%CustomDomain{dkim_selector: selector, dkim_private_key: private_key})
       when is_binary(selector) and is_binary(private_key) do
    if Elektrine.Strings.present?(selector) and Elektrine.Strings.present?(private_key) do
      if sync_enabled?(), do: :ok, else: {:error, "Haraka DKIM sync is disabled"}
    else
      {:error, "DKIM key material is missing"}
    end
  end

  defp ensure_sync_ready(_), do: {:error, "DKIM key material is missing"}

  defp request_config(domain) do
    email_cfg = email_config()
    base_url = Keyword.get(email_cfg, :custom_domain_haraka_base_url)
    api_key = Keyword.get(email_cfg, :custom_domain_haraka_api_key)

    cond do
      !Elektrine.Strings.present?(base_url) ->
        {:error, "Haraka DKIM sync base URL is not configured"}

      !Elektrine.Strings.present?(api_key) ->
        {:error, "Haraka DKIM sync API key is not configured"}

      true ->
        path =
          email_cfg
          |> Keyword.get(:custom_domain_haraka_dkim_path, @default_haraka_path)
          |> String.trim_trailing("/")

        {:ok,
         %{
           url: "#{String.trim_trailing(base_url, "/")}#{path}/#{URI.encode(domain)}",
           headers: [
             {"content-type", "application/json"},
             {"x-api-key", api_key},
             {"user-agent", "Elektrine-Custom-Domain-DKIM/1.0"}
           ],
           timeout: Keyword.get(email_cfg, :custom_domain_haraka_timeout, @default_timeout_ms)
         }}
    end
  end

  defp sync_enabled? do
    Keyword.get(email_config(), :custom_domain_dkim_sync_enabled, true)
  end

  defp normalize_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} when is_binary(error) -> error
      {:ok, %{"message" => message}} when is_binary(message) -> message
      _ -> String.trim(body)
    end
  end

  defp normalize_error_body(body), do: inspect(body)

  defp dmarc_rua_fragment(value) when is_binary(value),
    do: if(Elektrine.Strings.present?(value), do: "rua=mailto:#{value}", else: nil)

  defp dmarc_rua_fragment(_), do: nil

  defp configured_selector do
    email_config()
    |> Keyword.get(:custom_domain_dkim_selector, @default_selector)
    |> normalize_selector()
  end

  defp normalize_selector(selector) when is_binary(selector) do
    selector
    |> String.trim()
    |> case do
      "" -> @default_selector
      value -> value
    end
  end

  defp default_mail_host do
    Elektrine.Domains.primary_email_domain()
  end

  defp email_config do
    Elektrine.RuntimeEnv.app_config(:email, [])
  end

  defp http_client do
    Keyword.get(email_config(), :custom_domain_http_client, Elektrine.Email.DKIM.FinchClient)
  end

  defp generate_key_pair do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})

    private_pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])

    {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _e1, _e2, _c, _other} = private_key
    public_key = {:RSAPublicKey, modulus, exponent}

    public_pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)])

    {public_pem, private_pem}
  end
end
