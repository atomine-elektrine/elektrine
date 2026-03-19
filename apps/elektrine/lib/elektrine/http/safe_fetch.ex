defmodule Elektrine.HTTP.SafeFetch do
  @moduledoc """
  Streams remote HTTP responses with an optional body-size cap.
  """

  @default_max_body_bytes 2 * 1024 * 1024

  def request(request, finch_name, opts \\ []) do
    max_body_bytes = Keyword.get(opts, :max_body_bytes, @default_max_body_bytes)

    stream_opts =
      opts
      |> Keyword.take([:receive_timeout, :pool_timeout])

    initial = %{status: nil, headers: [], body: [], body_size: 0, too_large?: false}

    case Finch.stream(
           request,
           finch_name,
           initial,
           &stream_chunk(&1, &2, max_body_bytes),
           stream_opts
         ) do
      {:ok, %{too_large?: true}} ->
        {:error, :too_large}

      {:ok, %{status: status, headers: headers, body: body}} when is_integer(status) ->
        {:ok,
         %Finch.Response{
           status: status,
           headers: headers,
           body: body |> Enum.reverse() |> IO.iodata_to_binary()
         }}

      {:ok, _acc} ->
        {:error, :invalid_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_chunk({:status, status}, acc, _max_body_bytes), do: {:cont, %{acc | status: status}}

  defp stream_chunk({:headers, headers}, acc, max_body_bytes) do
    if content_length_too_large?(headers, max_body_bytes) do
      {:halt, %{acc | headers: headers, too_large?: true}}
    else
      {:cont, %{acc | headers: headers}}
    end
  end

  defp stream_chunk({:data, data}, acc, max_body_bytes) do
    new_size = acc.body_size + byte_size(data)

    if is_integer(max_body_bytes) and new_size > max_body_bytes do
      {:halt, %{acc | too_large?: true, body_size: new_size}}
    else
      {:cont, %{acc | body: [data | acc.body], body_size: new_size}}
    end
  end

  defp stream_chunk({:trailers, _trailers}, acc, _max_body_bytes), do: {:cont, acc}

  defp content_length_too_large?(_headers, nil), do: false

  defp content_length_too_large?(headers, max_body_bytes) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(name) == "content-length", do: parse_integer(value)
    end)
    |> case do
      length when is_integer(length) -> length > max_body_bytes
      _ -> false
    end
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil
end
