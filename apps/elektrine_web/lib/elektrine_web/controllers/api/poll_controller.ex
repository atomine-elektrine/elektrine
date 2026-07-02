defmodule ElektrineWeb.API.PollController do
  @moduledoc """
  API endpoints for reading and voting on polls.
  """
  use ElektrineWeb, :controller

  action_fallback ElektrineWeb.FallbackController

  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, poll} <- social().get_poll(id),
         true <- visible_poll?(poll, user.id) do
      json(conn, format_poll(poll, user.id))
    else
      _ -> not_found(conn)
    end
  end

  def vote(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with {:ok, poll} <- social().get_poll(id),
         true <- visible_poll?(poll, user.id),
         {:ok, updated_poll} <-
           social().set_poll_votes(poll.id, vote_choices(params), user.id) do
      json(conn, format_poll(updated_poll, user.id))
    else
      {:error, :poll_closed} ->
        validation_error(conn, "poll is closed")

      {:error, :self_vote} ->
        validation_error(conn, "cannot vote on your own poll")

      {:error, :invalid_option} ->
        validation_error(conn, "invalid poll option")

      {:error, :multiple_votes_not_allowed} ->
        validation_error(conn, "poll only allows one choice")

      {:error, :invalid_vote} ->
        validation_error(conn, "poll vote cannot be empty")

      _ ->
        not_found(conn)
    end
  end

  def delete_votes(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, poll} <- social().get_poll(id),
         true <- visible_poll?(poll, user.id),
         {:ok, updated_poll} <- social().clear_poll_votes(poll.id, user.id) do
      json(conn, format_poll(updated_poll, user.id))
    else
      _ -> not_found(conn)
    end
  end

  defp visible_poll?(%{message: message}, user_id) when not is_nil(message) do
    social().status_visible?(user_id, message)
  end

  defp visible_poll?(_poll, _user_id), do: false

  defp vote_choices(%{"choices" => choices}) when is_list(choices), do: choices
  defp vote_choices(%{"choices" => choice}), do: [choice]
  defp vote_choices(%{"choice" => choice}), do: [choice]
  defp vote_choices(%{"option_id" => option_id}), do: [option_id]
  defp vote_choices(_params), do: []

  defp format_poll(poll, user_id) do
    ElektrineWeb.API.PollJSON.format_poll(poll, user_id)
  end

  defp validation_error(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: message})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "poll not found"})
  end

  defp social, do: Module.concat([Elektrine, Social])
end
