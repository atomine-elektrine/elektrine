defmodule ElektrineSocialWeb.MastodonAPI.PollController do
  @moduledoc """
  Mastodon-compatible poll endpoints.
  """

  use ElektrineSocialWeb, :controller

  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Poll
  alias ElektrineSocialWeb.MastodonAPI.StatusView

  action_fallback(ElektrineSocialWeb.MastodonAPI.FallbackController)

  def show(conn, %{"id" => id}) do
    with {:ok, poll} <- fetch_poll(id) do
      json(conn, StatusView.render_poll(poll, conn.assigns[:user]))
    end
  end

  def vote(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def vote(%{assigns: %{user: user}} = conn, %{"id" => id, "choices" => choices}) do
    with {:ok, poll} <- fetch_poll(id),
         :ok <- submit_votes(poll, choices, user.id) do
      json(conn, StatusView.render_poll(fetch_poll!(poll.id), user))
    end
  end

  defp fetch_poll(id) do
    case parse_int(id) do
      nil ->
        {:error, :not_found}

      poll_id ->
        case Repo.get(Poll, poll_id) do
          nil -> {:error, :not_found}
          poll -> {:ok, Repo.preload(poll, [:options])}
        end
    end
  end

  defp fetch_poll!(id), do: Repo.get!(Poll, id) |> Repo.preload([:options])

  defp submit_votes(poll, choices, user_id) when is_list(choices) do
    choices
    |> Enum.map(&parse_int/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(:ok, fn option_id, :ok ->
      case Social.vote_on_poll(poll.id, option_id, user_id) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp submit_votes(_poll, _choices, _user_id),
    do: {:error, :unprocessable_entity, "Missing choices"}

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end
end
