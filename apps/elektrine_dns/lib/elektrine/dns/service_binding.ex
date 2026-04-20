defmodule Elektrine.DNS.ServiceBinding do
  @moduledoc false

  @param_keys %{
    "mandatory" => 0,
    "alpn" => 1,
    "no-default-alpn" => 2,
    "port" => 3,
    "ipv4hint" => 4,
    "ech" => 5,
    "ipv6hint" => 6
  }

  @reverse_param_keys Map.new(@param_keys, fn {key, value} -> {value, key} end)

  def normalize_content(content) when is_binary(content) do
    with {:ok, %{target: target, params: params}} <- parse_content(content) do
      normalized_params =
        params
        |> Enum.map_join(" ", fn
          {key, nil} -> key
          {key, value} -> key <> "=" <> value
        end)

      {:ok, String.trim([normalize_target(target), normalized_params] |> Enum.join(" "))}
    end
  end

  def normalize_content(_), do: {:error, "must include a target hostname"}

  def parse_content(content) when is_binary(content) do
    case String.split(String.trim(content), ~r/\s+/, trim: true) do
      [] ->
        {:error, "must include a target hostname"}

      [target | params] ->
        with {:ok, normalized_target} <- validate_target(target),
             {:ok, parsed_params} <- parse_params(params) do
          {:ok, %{target: normalized_target, params: parsed_params}}
        end
    end
  end

  def parse_content(_), do: {:error, "must include a target hostname"}

  def encode_rdata(priority, content, encode_name_fun) when is_function(encode_name_fun, 1) do
    with {:ok, %{target: target, params: params}} <- parse_content(content),
         {:ok, encoded_params} <- encode_params(params) do
      {:ok, <<priority::16, encode_name_fun.(target)::binary, encoded_params::binary>>}
    end
  end

  def param_key_name(code), do: Map.get(@reverse_param_keys, code, "key#{code}")

  defp validate_target("."), do: {:ok, "."}

  defp validate_target(target) do
    normalized = normalize_target(target)

    if normalized == "" do
      {:error, "must include a target hostname"}
    else
      {:ok, normalized}
    end
  end

  defp normalize_target("."), do: "."

  defp normalize_target(target) do
    target
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp parse_params(params) do
    Enum.reduce_while(params, {:ok, []}, fn token, {:ok, acc} ->
      case parse_param(token) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_param(token) do
    case String.split(token, "=", parts: 2) do
      [key] ->
        normalized_key = normalize_param_key(key)

        if normalized_key == "no-default-alpn" do
          {:ok, {normalized_key, nil}}
        else
          {:error, "parameter #{key} must use key=value format"}
        end

      [key, value] ->
        normalized_key = normalize_param_key(key)

        cond do
          normalized_key == "" ->
            {:error, "parameter names cannot be empty"}

          normalized_key == "no-default-alpn" and String.trim(value) != "" ->
            {:error, "no-default-alpn does not take a value"}

          true ->
            {:ok, {normalized_key, normalize_param_value(value)}}
        end
    end
  end

  defp normalize_param_key(key) do
    key
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_param_value(value) do
    value
    |> String.trim()
    |> String.trim("\"")
  end

  defp encode_params(params) do
    params
    |> Enum.map(fn {key, value} ->
      with {:ok, code} <- param_code(key),
           {:ok, encoded_value} <- encode_param_value(code, value) do
        {:ok, {code, <<code::16, byte_size(encoded_value)::16, encoded_value::binary>>}}
      end
    end)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, encoded}, {:ok, acc} -> {:cont, {:ok, [encoded | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, encoded} ->
        {:ok,
         encoded
         |> Enum.sort_by(fn {code, _bin} -> code end)
         |> Enum.map_join(fn {_code, bin} -> bin end)}

      error ->
        error
    end
  end

  defp param_code(key) do
    cond do
      Map.has_key?(@param_keys, key) ->
        {:ok, Map.fetch!(@param_keys, key)}

      String.match?(key, ~r/^key\d+$/) ->
        {:ok, key |> String.replace_prefix("key", "") |> String.to_integer()}

      true ->
        {:error, "unsupported parameter #{key}"}
    end
  end

  defp encode_param_value(0, value) when is_binary(value) do
    value
    |> split_csv_values()
    |> Enum.map(&param_code/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, code}, {:ok, acc} -> {:cont, {:ok, [<<code::16>> | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded) |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp encode_param_value(1, value) when is_binary(value) do
    {:ok,
     value
     |> split_csv_values()
     |> Enum.map(fn protocol -> <<byte_size(protocol)::8, protocol::binary>> end)
     |> IO.iodata_to_binary()}
  end

  defp encode_param_value(2, nil), do: {:ok, <<>>}

  defp encode_param_value(3, value) when is_binary(value) do
    case Integer.parse(value) do
      {port, ""} when port >= 0 and port <= 65_535 -> {:ok, <<port::16>>}
      _ -> {:error, "port parameter must be an integer between 0 and 65535"}
    end
  end

  defp encode_param_value(4, value) when is_binary(value), do: encode_ip_hints(value, :ipv4)

  defp encode_param_value(5, value) when is_binary(value) do
    case Base.decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "ech parameter must be base64 data"}
    end
  end

  defp encode_param_value(6, value) when is_binary(value), do: encode_ip_hints(value, :ipv6)
  defp encode_param_value(_code, value) when is_binary(value), do: {:ok, value}
  defp encode_param_value(_code, nil), do: {:ok, <<>>}

  defp encode_ip_hints(value, family) do
    value
    |> split_csv_values()
    |> Enum.map(&parse_ip_hint(&1, family))
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, encoded}, {:ok, acc} -> {:cont, {:ok, [encoded | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded) |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp parse_ip_hint(ip, family) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} when tuple_size(tuple) == 4 and family == :ipv4 ->
        {:ok, tuple |> Tuple.to_list() |> IO.iodata_to_binary()}

      {:ok, tuple} when tuple_size(tuple) == 8 and family == :ipv6 ->
        {:ok, tuple |> Tuple.to_list() |> Enum.map(&<<&1::16>>) |> IO.iodata_to_binary()}

      _ ->
        {:error,
         "#{family_label(family)} parameter must contain valid #{family_label(family)} addresses"}
    end
  end

  defp split_csv_values(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp family_label(:ipv4), do: "ipv4hint"
  defp family_label(:ipv6), do: "ipv6hint"
end
