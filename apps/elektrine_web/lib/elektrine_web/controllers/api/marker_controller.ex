defmodule ElektrineWeb.API.MarkerController do
  @moduledoc """
  Mastodon/Pleroma-compatible timeline marker API.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Markers

  action_fallback ElektrineWeb.FallbackController

  def index(conn, params) do
    user = conn.assigns[:current_user]
    timelines = List.wrap(params["timeline"])

    markers =
      user.id
      |> Markers.list_markers(timelines)
      |> format_markers()

    json(conn, markers)
  end

  def upsert(conn, params) do
    user = conn.assigns[:current_user]

    case Markers.upsert_markers(user.id, params) do
      {:ok, markers} ->
        json(conn, format_markers(markers))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
    end
  end

  defp format_markers(markers) do
    Map.new(markers, fn {timeline, marker} ->
      {timeline, Markers.format_marker(marker)}
    end)
  end
end
