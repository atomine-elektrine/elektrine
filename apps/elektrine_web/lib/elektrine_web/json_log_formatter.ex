defmodule ElektrineWeb.JsonLogFormatter do
  @moduledoc """
  JSON log formatter for production environments.
  Outputs logs in JSON format so log pipelines can parse levels reliably.
  """

  @doc """
  Formats a log message as JSON.
  """
  def format(level, message, timestamp, metadata) do
    {date, {hour, minute, second, _millisecond}} = timestamp

    json = %{
      level: level,
      message: IO.chardata_to_string(message),
      timestamp: format_timestamp(date, hour, minute, second),
      metadata: format_metadata(metadata)
    }

    case Jason.encode(json) do
      {:ok, encoded} -> [encoded, "\n"]
      {:error, _} -> ["[#{level}] #{message}\n"]
    end
  rescue
    _ -> ["[#{level}] #{message}\n"]
  end

  defp format_timestamp({year, month, day}, hour, minute, second) do
    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [
      year,
      month,
      day,
      hour,
      minute,
      second
    ])
    |> IO.iodata_to_binary()
  end

  defp format_metadata(metadata) do
    metadata
    |> Enum.filter(fn {_k, v} -> v != nil end)
    |> Enum.map(fn {key, value} -> {key, redact_metadata(key, value)} end)
    |> Enum.into(%{})
  end

  defp redact_metadata(key, value) do
    key
    |> to_string()
    |> String.downcase()
    |> case do
      name
      when name in ["authorization", "cookie", "set-cookie", "token", "secret", "password"] ->
        "[redacted]"

      name ->
        if String.contains?(name, ["token", "secret", "password", "api_key"]) do
          "[redacted]"
        else
          value
        end
    end
  end
end
