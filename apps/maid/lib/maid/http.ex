defmodule Maid.HTTP do
  @moduledoc false

  @default_timeout_ms 5_000

  def get_json(url, headers \\ [], opts \\ []) when is_binary(url) and is_list(headers) do
    request_fun = Keyword.get(opts, :request_fun, &request/3)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    case request_fun.(url, headers, receive_timeout: timeout) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        Jason.decode(body)

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(url, headers, opts) do
    :get
    |> Finch.build(url, headers)
    |> Finch.request(finch_name(), opts)
  end

  defp finch_name do
    Application.get_env(:maid, :finch_name, Elektrine.Finch)
  end
end
