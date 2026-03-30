defmodule Elektrine.DNS.MailSecurity do
  @moduledoc false

  @default_mta_sts_mode "enforce"
  @default_mta_sts_max_age 86_400

  def mta_sts_txt_value(domain, settings) do
    "v=STSv1; id=#{mta_sts_id(domain, settings)}"
  end

  def tls_rpt_txt_value(domain, settings) do
    "v=TLSRPTv1; rua=#{tls_rpt_rua(domain, settings)}"
  end

  def mta_sts_policy(domain, settings) do
    (["version: STSv1", "mode: #{mta_sts_mode(settings)}"] ++
       Enum.map(mta_sts_mx_patterns(domain, settings), &"mx: #{&1}") ++
       ["max_age: #{mta_sts_max_age(settings)}"])
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  def mail_target(domain, settings) do
    case cleaned_binary(settings["mail_target"]) do
      nil -> domain
      "mail." <> same_domain when same_domain == domain -> domain
      target -> target
    end
  end

  def mta_sts_mode(settings) do
    case cleaned_binary(settings["mta_sts_mode"]) do
      mode when mode in ["enforce", "testing", "none"] -> mode
      _ -> @default_mta_sts_mode
    end
  end

  def mta_sts_max_age(settings) do
    settings["mta_sts_max_age"]
    |> parse_positive_int(@default_mta_sts_max_age)
  end

  def tls_rpt_rua(domain, settings) do
    cleaned_binary(settings["tls_rpt_rua"]) || "mailto:postmaster@#{domain}"
  end

  def mta_sts_mx_patterns(domain, settings) do
    settings["mta_sts_mx_patterns"]
    |> cleaned_binary()
    |> case do
      nil -> [mail_target(domain, settings)]
      patterns -> patterns |> split_values() |> default_if_empty([mail_target(domain, settings)])
    end
  end

  defp mta_sts_id(domain, settings) do
    [
      domain,
      mta_sts_mode(settings),
      Integer.to_string(mta_sts_max_age(settings))
      | mta_sts_mx_patterns(domain, settings)
    ]
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp split_values(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp default_if_empty([], fallback), do: fallback
  defp default_if_empty(values, _fallback), do: values

  defp cleaned_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp cleaned_binary(_), do: nil

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_, default), do: default
end
