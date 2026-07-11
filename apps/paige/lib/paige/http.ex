defmodule Paige.HTTP do
  @moduledoc false

  @default_timeout_ms 5_000

  def get_text(url, headers \\ [], opts \\ []) when is_binary(url) and is_list(headers) do
    request_fun = Keyword.get(opts, :request_fun, &request/3)
    timeout = opts |> Keyword.get(:timeout, @default_timeout_ms) |> normalize_timeout()

    case request_fun.(url, headers, receive_timeout: timeout) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status, body: _body}} when status in 200..299 ->
        {:error, :invalid_body}

      response ->
        response_error(response)
    end
  rescue
    _error -> {:error, :request_failed}
  catch
    :exit, _reason -> {:error, :request_failed}
  end

  def get_json(url, headers \\ [], opts \\ []) when is_binary(url) and is_list(headers) do
    request_fun = Keyword.get(opts, :request_fun, &request/3)
    timeout = opts |> Keyword.get(:timeout, @default_timeout_ms) |> normalize_timeout()

    case request_fun.(url, headers, receive_timeout: timeout) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode_json(body)

      response ->
        response_error(response)
    end
  rescue
    _error -> {:error, :request_failed}
  catch
    :exit, _reason -> {:error, :request_failed}
  end

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} -> {:ok, payload}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp decode_json(_body), do: {:error, :invalid_json}

  defp response_error({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp response_error({:ok, %{status: 403}}), do: {:error, :forbidden}

  defp response_error({:ok, %{status: 429} = response}),
    do: {:error, {:rate_limited, retry_after(response)}}

  defp response_error({:ok, %{status: status}}), do: {:error, {:http_status, status}}
  defp response_error({:error, reason}), do: {:error, reason}
  defp response_error(_response), do: {:error, :invalid_response}

  defp retry_after(%{headers: headers}) when is_list(headers) do
    Enum.find_value(headers, 60, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "retry-after", do: parse_retry_after(value)

      _header ->
        nil
    end)
  end

  defp retry_after(_response), do: 60

  defp parse_retry_after(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds > 0 -> min(seconds, 86_400)
      _invalid -> 60
    end
  end

  defp normalize_timeout(timeout) when is_integer(timeout), do: timeout |> max(100) |> min(15_000)
  defp normalize_timeout(_timeout), do: @default_timeout_ms

  defp request(url, headers, opts) do
    :get
    |> Finch.build(url, headers)
    |> Finch.request(finch_name(), opts)
  end

  defp finch_name do
    Application.get_env(:paige, :finch_name, Elektrine.Finch)
  end
end
