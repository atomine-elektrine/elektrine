defmodule ElektrineWeb.API.StatusReactionController do
  @moduledoc """
  API endpoints for status emoji reactions.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.Messages
  alias ElektrineWeb.API.AccountJSON
  alias ElektrineWeb.API.StatusJSON

  action_fallback ElektrineWeb.FallbackController

  def index(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    case visible_status(id, user.id) do
      %Message{} = status ->
        reactions =
          status.id
          |> social().list_status_reactions()
          |> maybe_filter_muted(user.id, truthy?(params["with_muted"]))
          |> format_reaction_groups(user.id)

        json(conn, reactions)

      nil ->
        not_found(conn)
    end
  end

  def show(conn, %{"id" => id, "emoji" => emoji} = params) do
    user = conn.assigns[:current_user]

    case visible_status(id, user.id) do
      %Message{} = status ->
        reactions =
          status.id
          |> social().list_status_reactions(emoji: emoji)
          |> maybe_filter_muted(user.id, truthy?(params["with_muted"]))
          |> format_reaction_groups(user.id)

        json(conn, reactions)

      nil ->
        not_found(conn)
    end
  end

  def create(conn, %{"id" => id, "emoji" => emoji}) do
    user = conn.assigns[:current_user]

    case social().add_status_reaction(user.id, id, emoji) do
      {:ok, _reaction} -> status_response(conn, id, user.id)
      {:error, :rate_limited} -> rate_limited(conn)
      {:error, _reason} -> not_found(conn)
    end
  end

  def delete(conn, %{"id" => id, "emoji" => emoji}) do
    user = conn.assigns[:current_user]

    case social().remove_status_reaction(user.id, id, emoji) do
      {:ok, _reaction} -> status_response(conn, id, user.id)
      {:error, :not_found} -> status_response(conn, id, user.id)
      {:error, _reason} -> not_found(conn)
    end
  end

  defp status_response(conn, id, user_id) do
    case visible_status(id, user_id) do
      %Message{} = status ->
        status =
          status
          |> Repo.preload(Messages.timeline_feed_preloads() ++ [:message_stat])
          |> Message.decrypt_content()

        json(conn, StatusJSON.format_statuses([status], user_id) |> List.first())

      nil ->
        not_found(conn)
    end
  end

  defp visible_status(id, user_id) do
    Message
    |> Repo.get(id)
    |> case do
      %Message{} = status ->
        if social().status_visible?(user_id, status), do: status

      nil ->
        nil
    end
  rescue
    Ecto.Query.CastError -> nil
  end

  defp maybe_filter_muted(reactions, _user_id, true), do: reactions

  defp maybe_filter_muted(reactions, user_id, _with_muted) do
    Enum.reject(reactions, fn
      %{user_id: reacted_user_id} when is_integer(reacted_user_id) ->
        Accounts.user_muted?(user_id, reacted_user_id)

      _reaction ->
        false
    end)
  end

  defp format_reaction_groups(reactions, user_id) do
    reactions
    |> Enum.group_by(fn reaction -> {reaction.emoji, reaction.emoji_url} end)
    |> Enum.map(fn {{emoji, emoji_url}, grouped_reactions} ->
      %{
        name: emoji,
        count: length(grouped_reactions),
        me: Enum.any?(grouped_reactions, &(&1.user_id == user_id)),
        url: emoji_url,
        accounts: Enum.map(grouped_reactions, &format_reaction_account(&1, user_id))
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp format_reaction_account(%{user: user}, viewer_id),
    do: AccountJSON.format_account(user, viewer_id)

  defp format_reaction_account(%{remote_actor: actor}, viewer_id),
    do: AccountJSON.format_account(actor, viewer_id)

  defp format_reaction_account(_reaction, _viewer_id), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_value), do: false

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end

  defp rate_limited(conn) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{error: "rate limited"})
  end

  defp social, do: Module.concat([Elektrine, Social])
end
