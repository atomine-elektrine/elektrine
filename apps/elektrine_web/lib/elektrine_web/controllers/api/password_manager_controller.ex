defmodule ElektrineWeb.API.PasswordManagerController do
  @moduledoc """
  External API controller for encrypted password manager entries.
  """
  use ElektrineWeb, :controller

  alias Elektrine.PasswordManager

  action_fallback ElektrineWeb.FallbackController

  @doc """
  GET /api/ext/password-manager/entries
  """
  def index(conn, _params) do
    user = conn.assigns.current_user
    entries = PasswordManager.list_entries(user.id)

    conn
    |> put_status(:ok)
    |> json(%{entries: entries})
  end

  @doc """
  POST /api/ext/password-manager/entries
  """
  def create(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.get(params, "entry", params)

    case PasswordManager.create_entry(user.id, attrs) do
      {:ok, entry} ->
        conn
        |> put_status(:created)
        |> json(%{entry: format_entry(entry)})

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  GET /api/ext/password-manager/entries/:id
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, entry_id} <- parse_id(id),
         {:ok, entry} <- PasswordManager.get_entry(user.id, entry_id) do
      conn
      |> put_status(:ok)
      |> json(%{entry: format_entry(entry, reveal: true)})
    end
  end

  @doc """
  DELETE /api/ext/password-manager/entries/:id
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, entry_id} <- parse_id(id),
         {:ok, _entry} <- PasswordManager.delete_entry(user.id, entry_id) do
      conn
      |> put_status(:ok)
      |> json(%{message: "Entry deleted"})
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

  defp format_entry(entry, opts \\ []) do
    reveal? = Keyword.get(opts, :reveal, false)

    %{
      id: entry.id,
      title: entry.title,
      login_username: entry.login_username,
      website: entry.website,
      notes: if(reveal?, do: entry.notes, else: nil),
      password: if(reveal?, do: entry.password, else: nil),
      inserted_at: entry.inserted_at,
      updated_at: entry.updated_at
    }
  end
end
