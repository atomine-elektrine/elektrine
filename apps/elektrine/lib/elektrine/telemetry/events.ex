defmodule Elektrine.Telemetry.Events do
  @moduledoc """
  Shared telemetry emitters for application business events.

  These helpers keep event naming and tag formats consistent across modules.
  """

  @spec auth(atom() | binary(), atom() | binary(), map()) :: :ok
  def auth(flow, outcome, metadata \\ %{}) do
    :telemetry.execute(
      [:elektrine, :auth, :flow],
      %{count: 1},
      metadata
      |> Map.merge(%{
        flow: normalize_tag(flow),
        outcome: normalize_tag(outcome)
      })
      |> normalize_metadata()
    )

    :ok
  end

  @spec email_inbound(atom() | binary(), atom() | binary(), integer() | nil, map()) :: :ok
  def email_inbound(stage, outcome, duration_ms \\ nil, metadata \\ %{}) do
    :telemetry.execute(
      [:elektrine, :email, :inbound],
      base_measurements(duration_ms),
      metadata
      |> Map.merge(%{
        stage: normalize_tag(stage),
        outcome: normalize_tag(outcome)
      })
      |> normalize_metadata()
    )

    :ok
  end

  @spec email_outbound(atom() | binary(), atom() | binary(), integer() | nil, map()) :: :ok
  def email_outbound(stage, outcome, duration_ms \\ nil, metadata \\ %{}) do
    :telemetry.execute(
      [:elektrine, :email, :outbound],
      base_measurements(duration_ms),
      metadata
      |> Map.merge(%{
        stage: normalize_tag(stage),
        outcome: normalize_tag(outcome)
      })
      |> normalize_metadata()
    )

    :ok
  end

  @spec federation(
          atom() | binary(),
          atom() | binary(),
          atom() | binary(),
          integer() | nil,
          map()
        ) ::
          :ok
  def federation(component, event, outcome, duration_ms \\ nil, metadata \\ %{}) do
    :telemetry.execute(
      [:elektrine, :federation, :event],
      base_measurements(duration_ms),
      metadata
      |> Map.merge(%{
        component: normalize_tag(component),
        event: normalize_tag(event),
        outcome: normalize_tag(outcome)
      })
      |> normalize_metadata()
    )

    :ok
  end

  @spec cert(atom() | binary(), atom() | binary(), atom() | binary(), integer() | nil, map()) ::
          :ok
  def cert(component, event, outcome, duration_ms \\ nil, metadata \\ %{}) do
    :telemetry.execute(
      [:elektrine, :cert, :lifecycle],
      base_measurements(duration_ms),
      metadata
      |> Map.merge(%{
        component: normalize_tag(component),
        event: normalize_tag(event),
        outcome: normalize_tag(outcome)
      })
      |> normalize_metadata()
    )

    :ok
  end

  @spec cert_status(non_neg_integer(), non_neg_integer(), map()) :: :ok
  def cert_status(expiring_count, total_count, metadata \\ %{}) do
    :telemetry.execute(
      [:elektrine, :cert, :status],
      %{expiring: expiring_count, total: total_count},
      normalize_metadata(metadata)
    )

    :ok
  end

  @spec upload(atom() | binary(), atom() | binary(), integer() | nil, map()) :: :ok
  def upload(type, outcome, bytes \\ nil, metadata \\ %{}) do
    measurements =
      %{count: 1}
      |> maybe_put_bytes(bytes)

    :telemetry.execute(
      [:elektrine, :upload, :operation],
      measurements,
      metadata
      |> Map.merge(%{
        type: normalize_tag(type),
        outcome: normalize_tag(outcome)
      })
      |> normalize_metadata()
    )

    :ok
  end

  @spec cache(atom() | binary(), atom() | binary(), atom() | binary(), map()) :: :ok
  def cache(cache_name, operation, result, metadata \\ %{}) do
    :telemetry.execute(
      [:elektrine, :cache, :request],
      %{count: 1},
      metadata
      |> Map.merge(%{
        cache: normalize_tag(cache_name),
        op: normalize_tag(operation),
        result: normalize_tag(result)
      })
      |> normalize_metadata()
    )

    :ok
  end

  @spec api_request(integer(), integer(), map()) :: :ok
  def api_request(duration_ms, status_code, metadata \\ %{}) do
    :telemetry.execute(
      [:elektrine, :api, :request],
      %{count: 1, duration: duration_ms},
      metadata
      |> Map.merge(%{
        status_class: status_class(status_code)
      })
      |> normalize_metadata()
    )

    :ok
  end

  @spec dav_request(integer(), integer(), map()) :: :ok
  def dav_request(duration_ms, status_code, metadata \\ %{}) do
    :telemetry.execute(
      [:elektrine, :dav, :request],
      %{count: 1, duration: duration_ms},
      metadata
      |> Map.merge(%{
        status_class: status_class(status_code)
      })
      |> normalize_metadata()
    )

    :ok
  end

  defp base_measurements(nil), do: %{count: 1}
  defp base_measurements(duration_ms), do: %{count: 1, duration: duration_ms}

  defp maybe_put_bytes(measurements, nil), do: measurements

  defp maybe_put_bytes(measurements, bytes) when is_integer(bytes),
    do: Map.put(measurements, :bytes, bytes)

  defp maybe_put_bytes(measurements, _), do: measurements

  defp normalize_metadata(metadata) do
    metadata
    |> Enum.into(%{}, fn {key, value} -> {key, normalize_tag(value)} end)
  end

  defp normalize_tag(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_tag(value) when is_binary(value), do: value
  defp normalize_tag(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_tag(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 2])

  defp normalize_tag(value), do: inspect(value)

  defp status_class(code) when is_integer(code) do
    "#{div(code, 100)}xx"
  end

  defp status_class(_), do: "unknown"
end
