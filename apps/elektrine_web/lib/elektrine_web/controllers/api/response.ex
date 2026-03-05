defmodule ElektrineWeb.API.Response do
  @moduledoc """
  Shared JSON response helpers for external API endpoints.

  All responses include `meta.request_id` when available.
  """

  import Plug.Conn
  import Phoenix.Controller

  @type error_details :: map() | list() | String.t() | nil

  def ok(conn, data, meta \\ %{}) do
    respond(conn, :ok, data, meta)
  end

  def created(conn, data, meta \\ %{}) do
    respond(conn, :created, data, meta)
  end

  def accepted(conn, data, meta \\ %{}) do
    respond(conn, :accepted, data, meta)
  end

  def error(conn, status, code, message, details \\ nil, meta \\ %{}) do
    payload =
      %{error: %{code: code, message: message}}
      |> maybe_put_details(details)
      |> Map.put(:meta, with_request_id(conn, meta))

    conn
    |> put_status(status)
    |> json(payload)
  end

  defp respond(conn, status, data, meta) do
    conn
    |> put_status(status)
    |> json(%{
      data: data,
      meta: with_request_id(conn, meta)
    })
  end

  defp maybe_put_details(payload, nil), do: payload
  defp maybe_put_details(payload, details), do: put_in(payload, [:error, :details], details)

  defp with_request_id(conn, meta) when is_map(meta) do
    request_id =
      conn
      |> get_resp_header("x-request-id")
      |> List.first()
      |> case do
        nil ->
          conn
          |> get_req_header("x-request-id")
          |> List.first()

        value ->
          value
      end

    if is_binary(request_id) and request_id != "" do
      Map.put(meta, :request_id, request_id)
    else
      meta
    end
  end
end
