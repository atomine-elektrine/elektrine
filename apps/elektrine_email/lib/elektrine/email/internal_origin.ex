defmodule Elektrine.Email.InternalOrigin do
  @moduledoc false

  alias Elektrine.Email.InboundRouting
  alias Elektrine.EmailConfig

  @max_age_seconds 900

  def sign_params(params) when is_map(params) do
    from = params[:from] || params["from"] || ""
    headers = params[:headers] || params["headers"] || %{}

    signed_headers = sign_headers(headers, from)

    cond do
      Map.has_key?(params, :headers) -> Map.put(params, :headers, signed_headers)
      Map.has_key?(params, "headers") -> Map.put(params, "headers", signed_headers)
      signed_headers == %{} -> params
      true -> Map.put(params, :headers, signed_headers)
    end
  end

  def sign_params(params), do: params

  def sign_headers(headers, from, now \\ System.system_time(:second)) do
    headers = if is_map(headers), do: headers, else: %{}

    case signing_secret() do
      secret when is_binary(secret) and secret != "" ->
        ts = Integer.to_string(now)
        payload = payload(from, ts)
        signature = Base.encode16(:crypto.mac(:hmac, :sha256, secret, payload), case: :lower)

        headers
        |> Map.put("X-Elektrine-Origin", "internal")
        |> Map.put("X-Elektrine-Origin-Ts", ts)
        |> Map.put("X-Elektrine-Origin-Sig", signature)

      _ ->
        headers
    end
  end

  def valid?(headers, from, now \\ System.system_time(:second)) do
    with secret when is_binary(secret) <- signing_secret(),
         true <- Elektrine.Strings.present?(secret),
         headers when is_map(headers) <- headers || %{},
         "internal" <- header_value(headers, ["x-elektrine-origin", "X-Elektrine-Origin"]),
         ts when is_binary(ts) <-
           header_value(headers, ["x-elektrine-origin-ts", "X-Elektrine-Origin-Ts"]),
         true <- Elektrine.Strings.present?(ts),
         signature when is_binary(signature) <-
           header_value(headers, ["x-elektrine-origin-sig", "X-Elektrine-Origin-Sig"]),
         true <- Elektrine.Strings.present?(signature),
         {timestamp, ""} <- Integer.parse(ts),
         true <- timestamp_fresh?(timestamp, now) do
      expected =
        Base.encode16(:crypto.mac(:hmac, :sha256, secret, payload(from, ts)), case: :lower)

      secure_compare(signature, expected)
    else
      _ -> false
    end
  end

  defp signing_secret do
    EmailConfig.internal_signing_secret()
  end

  defp header_value(headers, candidates) do
    Enum.find_value(candidates, fn key ->
      case Map.get(headers, key) do
        value when is_binary(value) -> String.trim(value)
        _ -> nil
      end
    end)
  end

  defp timestamp_fresh?(timestamp, now) when is_integer(timestamp) and is_integer(now) do
    abs(now - timestamp) <= @max_age_seconds
  end

  defp payload(from, ts) do
    clean_from =
      from
      |> InboundRouting.extract_clean_email()
      |> case do
        nil -> ""
        email -> String.downcase(email)
      end

    "internal|#{ts}|#{clean_from}"
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right) do
    false
  end
end
