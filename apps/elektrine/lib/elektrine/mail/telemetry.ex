defmodule Elektrine.Mail.Telemetry do
  @moduledoc """
  Shared telemetry helpers for mailbox protocols (IMAP/POP3/SMTP).
  """

  @spec auth(atom(), atom(), map()) :: :ok
  def auth(protocol, outcome, metadata \\ %{}) do
    :telemetry.execute(
      [:elektrine, :mail, :auth],
      %{count: 1},
      Map.merge(%{protocol: protocol, outcome: outcome}, sanitize_metadata(metadata))
    )

    :ok
  end

  @spec command(atom(), String.t() | atom(), non_neg_integer(), atom()) :: :ok
  def command(protocol, command, duration_us, outcome \\ :ok) do
    :telemetry.execute(
      [:elektrine, :mail, :command],
      %{duration: duration_us},
      %{protocol: protocol, command: normalize_command(command), outcome: outcome}
    )

    :ok
  end

  @spec sessions(atom(), non_neg_integer(), non_neg_integer()) :: :ok
  def sessions(protocol, total, per_ip) do
    :telemetry.execute(
      [:elektrine, :mail, :sessions],
      %{total: total, per_ip: per_ip},
      %{protocol: protocol}
    )

    :ok
  end

  defp sanitize_metadata(metadata) do
    metadata
    |> Map.take([:reason, :source, :ratelimit])
    |> Enum.into(%{}, fn {k, v} -> {k, sanitize_value(v)} end)
  end

  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_value(value) when is_binary(value), do: value
  defp sanitize_value(value), do: inspect(value)

  defp normalize_command(command) when is_atom(command),
    do: command |> Atom.to_string() |> String.upcase()

  defp normalize_command(command) when is_binary(command), do: String.upcase(command)
  defp normalize_command(_command), do: "UNKNOWN"
end
