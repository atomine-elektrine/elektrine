defmodule ElektrineWeb.API.DNSController do
  @moduledoc """
  External API controller for managed DNS zones and records.
  """

  use ElektrineDNSWeb, :controller

  alias Elektrine.DNS
  alias Elektrine.DNS.Zone
  alias ElektrineWeb.API.Response

  action_fallback ElektrineWeb.FallbackController

  def index(conn, _params) do
    user = conn.assigns.current_user

    Response.ok(conn, %{zones: Enum.map(DNS.list_user_zones(user.id), &format_zone/1)})
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, zone_id} <- parse_id(id),
         %Zone{} = zone <- DNS.get_zone(zone_id, user.id) do
      Response.ok(conn, %{zone: format_zone(zone, include_records: true)})
    else
      {:error, :bad_request} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid zone id")

      nil ->
        Response.error(conn, :not_found, "not_found", "Zone not found")
    end
  end

  def create(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.get(params, "zone", params)

    case DNS.create_zone(user, attrs) do
      {:ok, zone} ->
        Response.created(conn, %{zone: format_zone(zone)})

      {:error, changeset} ->
        Response.error(
          conn,
          :unprocessable_entity,
          "validation_failed",
          "Invalid zone",
          errors_on(changeset)
        )
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    attrs = Map.get(params, "zone", params)

    with {:ok, zone_id} <- parse_id(id),
         %Zone{} = zone <- DNS.get_zone(zone_id, user.id),
         {:ok, zone} <- DNS.update_zone(zone, attrs) do
      Response.ok(conn, %{zone: format_zone(zone)})
    else
      {:error, :bad_request} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid zone id")

      nil ->
        Response.error(conn, :not_found, "not_found", "Zone not found")

      {:error, changeset} ->
        Response.error(
          conn,
          :unprocessable_entity,
          "validation_failed",
          "Invalid zone",
          errors_on(changeset)
        )
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, zone_id} <- parse_id(id),
         %Zone{} = zone <- DNS.get_zone(zone_id, user.id),
         {:ok, _} <- DNS.delete_zone(zone) do
      Response.ok(conn, %{message: "Zone deleted"})
    else
      {:error, :bad_request} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid zone id")

      nil ->
        Response.error(conn, :not_found, "not_found", "Zone not found")

      {:error, changeset} ->
        Response.error(
          conn,
          :unprocessable_entity,
          "validation_failed",
          "Could not delete zone",
          errors_on(changeset)
        )
    end
  end

  def verify(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, zone_id} <- parse_id(id),
         %Zone{} = zone <- DNS.get_zone(zone_id, user.id),
         {:ok, zone} <- DNS.verify_zone(zone) do
      Response.ok(conn, %{zone: format_zone(zone, include_onboarding_records: true)})
    else
      {:error, :bad_request} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid zone id")

      nil ->
        Response.error(conn, :not_found, "not_found", "Zone not found")

      {:error, changeset} ->
        Response.error(
          conn,
          :unprocessable_entity,
          "validation_failed",
          "Verification failed",
          errors_on(changeset)
        )
    end
  end

  def create_record(conn, %{"zone_id" => zone_id} = params) do
    user = conn.assigns.current_user
    attrs = Map.get(params, "record", params)

    with {:ok, zone_id} <- parse_id(zone_id),
         %Zone{} = zone <- DNS.get_zone(zone_id, user.id),
         {:ok, record} <- DNS.create_record(zone, attrs) do
      Response.created(conn, %{record: format_record(record)})
    else
      {:error, :bad_request} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid zone id")

      nil ->
        Response.error(conn, :not_found, "not_found", "Zone not found")

      {:error, changeset} ->
        Response.error(
          conn,
          :unprocessable_entity,
          "validation_failed",
          "Invalid record",
          errors_on(changeset)
        )
    end
  end

  def update_record(conn, %{"zone_id" => zone_id, "id" => id} = params) do
    user = conn.assigns.current_user
    attrs = Map.get(params, "record", params)

    with {:ok, zone_id} <- parse_id(zone_id),
         {:ok, record_id} <- parse_id(id),
         %Zone{} <- DNS.get_zone(zone_id, user.id),
         %{} = record <- DNS.get_record(record_id, zone_id),
         {:ok, record} <- DNS.update_record(record, attrs) do
      Response.ok(conn, %{record: format_record(record)})
    else
      {:error, :bad_request} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid record or zone id")

      nil ->
        Response.error(conn, :not_found, "not_found", "Record not found")

      {:error, changeset} ->
        Response.error(
          conn,
          :unprocessable_entity,
          "validation_failed",
          "Invalid record",
          errors_on(changeset)
        )
    end
  end

  def delete_record(conn, %{"zone_id" => zone_id, "id" => id}) do
    user = conn.assigns.current_user

    with {:ok, zone_id} <- parse_id(zone_id),
         {:ok, record_id} <- parse_id(id),
         %Zone{} <- DNS.get_zone(zone_id, user.id),
         %{} = record <- DNS.get_record(record_id, zone_id),
         {:ok, _} <- DNS.delete_record(record) do
      Response.ok(conn, %{message: "Record deleted"})
    else
      {:error, :bad_request} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid record or zone id")

      nil ->
        Response.error(conn, :not_found, "not_found", "Record not found")

      {:error, changeset} ->
        Response.error(
          conn,
          :unprocessable_entity,
          "validation_failed",
          "Could not delete record",
          errors_on(changeset)
        )
    end
  end

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, :bad_request}
    end
  end

  defp parse_id(_), do: {:error, :bad_request}

  defp format_zone(zone, opts \\ []) do
    include_records? = Keyword.get(opts, :include_records, false)
    include_onboarding? = Keyword.get(opts, :include_onboarding_records, false)

    %{
      id: zone.id,
      domain: zone.domain,
      status: zone.status,
      kind: zone.kind,
      serial: zone.serial,
      default_ttl: zone.default_ttl,
      verified_at: zone.verified_at,
      last_checked_at: Map.get(zone, :last_checked_at),
      last_published_at: zone.last_published_at,
      last_error: zone.last_error,
      records:
        if(include_records?, do: Enum.map(zone.records || [], &format_record/1), else: nil),
      onboarding_records:
        if(include_onboarding?, do: DNS.zone_onboarding_records(zone), else: nil)
    }
  end

  defp format_record(record) do
    %{
      id: record.id,
      zone_id: record.zone_id,
      name: record.name,
      type: record.type,
      ttl: record.ttl,
      content: record.content,
      priority: record.priority,
      weight: record.weight,
      port: record.port,
      flags: record.flags,
      tag: record.tag,
      inserted_at: record.inserted_at,
      updated_at: record.updated_at
    }
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
