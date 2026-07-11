defmodule Elektrine.WebIndex.Fetcher do
  @moduledoc "SSRF-safe, size-limited HTTP fetching for the Paige crawler."

  alias Elektrine.HTTP.SafeFetch

  @user_agent "PaigeBot/1.0 (+https://elektrine.com/paige)"
  @max_redirects 4
  @max_body_bytes 2 * 1024 * 1024

  def get(url, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &request/3)
    follow(url, request_fun, opts, 0)
  end

  defp follow(url, request_fun, opts, redirects) when redirects <= @max_redirects do
    headers = [
      {"user-agent", @user_agent},
      {"accept", Keyword.get(opts, :accept, "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1")}
    ]

    case request_fun.(url, headers, opts) do
      {:ok, %{status: status, headers: response_headers}} when status in 300..399 ->
        with location when is_binary(location) <- header(response_headers, "location"),
             {:ok, target} <- redirect_url(url, location),
             :ok <- validate_redirect_scope(url, target, opts) do
          follow(target, request_fun, opts, redirects + 1)
        else
          _missing_or_invalid -> {:error, :invalid_redirect}
        end

      {:ok, %{status: status, body: body} = response} when is_binary(body) ->
        {:ok, %{status: status, body: body, headers: Map.get(response, :headers, []), url: url}}

      {:error, reason} ->
        {:error, reason}

      _response ->
        {:error, :invalid_response}
    end
  end

  defp follow(_url, _request_fun, _opts, _redirects), do: {:error, :too_many_redirects}

  defp request(url, headers, opts) do
    :get
    |> Finch.build(url, headers)
    |> SafeFetch.request(Elektrine.Finch,
      receive_timeout: Keyword.get(opts, :receive_timeout, 20_000),
      max_body_bytes: Keyword.get(opts, :max_body_bytes, @max_body_bytes)
    )
  end

  defp redirect_url(base_url, location) do
    target = base_url |> URI.parse() |> URI.merge(location) |> URI.to_string()

    case Elektrine.WebIndex.normalize_url(target) do
      {:ok, normalized, _host} -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :invalid_redirect}
  end

  defp validate_redirect_scope(source, target, opts) do
    if Keyword.get(opts, :same_host_redirects?, true) and
         URI.parse(source).host != URI.parse(target).host do
      {:error, :cross_host_redirect}
    else
      :ok
    end
  end

  defp header(headers, wanted) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == wanted, do: value
    end)
  end
end
