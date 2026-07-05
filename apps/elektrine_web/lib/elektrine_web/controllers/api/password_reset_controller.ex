defmodule ElektrineWeb.API.PasswordResetController do
  @moduledoc """
  JSON password reset endpoints for social API clients.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Vault

  def request(conn, params) do
    case reset_identifier(params) do
      identifier when is_binary(identifier) and identifier != "" ->
        _ = Accounts.initiate_password_reset(identifier)
        send_resp(conn, :no_content, "")

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "email or nickname is required"})
    end
  end

  def confirm(conn, params) do
    attrs = reset_attrs(params)

    with token when is_binary(token) and token != "" <- attrs["token"],
         {:ok, user} <-
           Accounts.reset_password_with_token(token, %{
             password: attrs["password"],
             password_confirmation: attrs["password_confirmation"]
           }) do
      json(conn, %{
        status: "ok",
        encrypted_data_recovery_required: Vault.configured?(user.id)
      })
    else
      {:error, :invalid_token} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_token"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_password", details: translate_errors(changeset)})

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "token is required"})
    end
  end

  defp reset_identifier(params) do
    [
      params["email"],
      params["nickname"],
      params["username"],
      params["username_or_email"],
      get_in(params, ["password_reset", "username_or_email"])
    ]
    |> Enum.map(&normalize_string/1)
    |> Enum.find(&(&1 && &1 != ""))
  end

  defp reset_attrs(%{"data" => data}) when is_map(data), do: stringify_keys(data)

  defp reset_attrs(%{"user" => user} = params) when is_map(user),
    do: Map.merge(stringify_keys(params), stringify_keys(user))

  defp reset_attrs(params), do: stringify_keys(params)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_value), do: nil

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
