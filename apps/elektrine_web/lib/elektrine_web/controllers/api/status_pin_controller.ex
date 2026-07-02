defmodule ElektrineWeb.API.StatusPinController do
  @moduledoc """
  API endpoints for profile timeline status pins.
  """
  use ElektrineWeb, :controller

  action_fallback ElektrineWeb.FallbackController

  def pin(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case social().pin_timeline_post(user.id, id) do
      {:ok, post} -> json(conn, format_status(post))
      {:error, reason} -> error(conn, reason)
    end
  end

  def unpin(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case social().unpin_timeline_post(user.id, id) do
      {:ok, post} -> json(conn, format_status(post))
      {:error, reason} -> error(conn, reason)
    end
  end

  defp format_status(post) do
    %{
      id: to_string(post.id),
      content: post.content,
      visibility: post.visibility,
      pinned: post.is_pinned || false,
      pinned_at: post.pinned_at
    }
  end

  defp error(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end

  defp error(conn, :unauthorized) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "forbidden"})
  end

  defp error(conn, :invalid_visibility) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "status visibility cannot be pinned"})
  end

  defp error(conn, :pin_limit_reached) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "pin limit reached"})
  end

  defp error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "unprocessable entity"})
  end

  defp social, do: Module.concat([Elektrine, Social])
end
