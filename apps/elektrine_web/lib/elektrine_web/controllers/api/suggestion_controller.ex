defmodule ElektrineWeb.API.SuggestionController do
  @moduledoc """
  JSON API for suggested local accounts.
  """

  use ElektrineWeb, :controller

  alias ElektrineWeb.API.AccountJSON

  def index(conn, params) do
    user = conn.assigns[:current_user]
    limit = parse_limit(params["limit"])

    suggestions =
      social().get_suggested_follows(user.id, limit: limit)

    accounts =
      suggestions
      |> Enum.map(&suggestion_user/1)
      |> AccountJSON.format_accounts(user)

    suggestions =
      suggestions
      |> Enum.zip(accounts)
      |> Enum.map(fn {suggestion, account} -> format_suggestion(suggestion, account) end)

    json(conn, suggestions)
  end

  def dismiss(conn, %{"account_id" => account_id}) do
    user = conn.assigns[:current_user]

    case parse_account_id(account_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "suggestion not found"})

      suggested_user_id ->
        case social().dismiss_suggested_follow(user.id, suggested_user_id) do
          {:ok, _dismissal} ->
            json(conn, %{})

          {:error, _reason} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "suggestion not found"})
        end
    end
  end

  defp format_suggestion(suggestion, account) do
    %{
      source: "past_interactions",
      sources: ["past_interactions"],
      reason: suggestion[:reason] || suggestion["reason"],
      account: account
    }
  end

  defp suggestion_user(%{user: user}), do: user
  defp suggestion_user(_suggestion), do: nil

  defp parse_limit(value) when is_integer(value), do: clamp_limit(value)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> clamp_limit(limit)
      _ -> 40
    end
  end

  defp parse_limit(_), do: 40

  defp clamp_limit(limit) when limit < 1, do: 1
  defp clamp_limit(limit) when limit > 80, do: 80
  defp clamp_limit(limit), do: limit

  defp parse_account_id(value) when is_integer(value) and value > 0, do: value

  defp parse_account_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp parse_account_id(_value), do: nil

  defp social, do: Module.concat([Elektrine, Social])
end
