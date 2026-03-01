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
    vault_configured = PasswordManager.vault_configured?(user.id)

    conn
    |> put_status(:ok)
    |> json(%{entries: entries, vault_configured: vault_configured})
  end

  @doc """
  POST /api/ext/password-manager/vault/setup
  """
  def setup(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.get(params, "vault", params)

    with {:ok, attrs} <- decode_setup_params(attrs),
         {:ok, _settings} <- PasswordManager.setup_vault(user.id, attrs) do
      conn
      |> put_status(:created)
      |> json(%{message: "Vault configured", vault_configured: true})
    end
  end

  @doc """
  POST /api/ext/password-manager/entries
  """
  def create(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.get(params, "entry", params)

    with {:ok, attrs} <- decode_encrypted_params(attrs) do
      case PasswordManager.create_entry(user.id, attrs) do
        {:ok, entry} ->
          conn
          |> put_status(:created)
          |> json(%{entry: format_entry(entry)})

        {:error, :vault_not_configured} ->
          conn
          |> put_status(:precondition_required)
          |> json(%{error: "vault_not_configured"})

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  GET /api/ext/password-manager/entries/:id
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, entry_id} <- parse_id(id),
         {:ok, entry} <- PasswordManager.get_entry_ciphertext(user.id, entry_id) do
      conn
      |> put_status(:ok)
      |> json(%{entry: format_entry(entry, include_ciphertext: true)})
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

  defp decode_setup_params(attrs) when is_map(attrs) do
    decode_payload_field(attrs, "encrypted_verifier", required: true)
  end

  defp decode_setup_params(_attrs), do: {:error, :bad_request}

  defp decode_encrypted_params(attrs) when is_map(attrs) do
    case decode_payload_field(attrs, "encrypted_password", required: true) do
      {:ok, decoded_attrs} ->
        decode_payload_field(decoded_attrs, "encrypted_notes", required: false)

      error ->
        error
    end
  end

  defp decode_encrypted_params(_attrs), do: {:error, :bad_request}

  defp decode_payload_field(attrs, field, opts) do
    required? = Keyword.get(opts, :required, false)

    case Map.get(attrs, field) do
      nil ->
        if required?, do: {:error, :bad_request}, else: {:ok, attrs}

      "" ->
        if required?, do: {:error, :bad_request}, else: {:ok, Map.put(attrs, field, nil)}

      value when is_map(value) ->
        {:ok, attrs}

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) -> {:ok, Map.put(attrs, field, decoded)}
          _ -> {:error, :bad_request}
        end

      _ ->
        {:error, :bad_request}
    end
  end

  defp format_entry(entry, opts \\ []) do
    include_ciphertext? = Keyword.get(opts, :include_ciphertext, false)

    %{
      id: entry.id,
      title: entry.title,
      login_username: entry.login_username,
      website: entry.website,
      encrypted_password: if(include_ciphertext?, do: entry.encrypted_password, else: nil),
      encrypted_notes: if(include_ciphertext?, do: entry.encrypted_notes, else: nil),
      inserted_at: entry.inserted_at,
      updated_at: entry.updated_at
    }
  end
end
