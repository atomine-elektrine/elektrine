defmodule ElektrinePasswordManagerWeb.API.VaultController do
  @moduledoc """
  External API controller for encrypted vault entries.
  """

  use ElektrinePasswordManagerWeb, :controller

  alias Elektrine.PasswordManager
  alias Elektrine.PasswordManager.Payloads
  alias ElektrinePasswordManagerWeb.API.Response

  @doc """
  GET /api/ext/v1/password-manager/entries
  """
  def index(conn, params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], 50) |> min(100)
    offset = parse_non_negative_int(params["offset"], 0)

    all_entries = PasswordManager.list_entries(user.id)
    entries = all_entries |> Enum.drop(offset) |> Enum.take(limit)
    vault_configured = PasswordManager.vault_configured?(user.id)

    Response.ok(
      conn,
      %{entries: entries, vault_configured: vault_configured},
      %{pagination: %{limit: limit, offset: offset, total_count: length(all_entries)}}
    )
  end

  @doc """
  POST /api/ext/v1/password-manager/vault/setup
  """
  def setup(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.get(params, "vault", params)

    with {:ok, attrs} <- Payloads.decode_setup_params(attrs),
         {:ok, _settings} <- PasswordManager.setup_vault(user.id, attrs) do
      Response.created(conn, %{message: "Vault configured", vault_configured: true})
    else
      {:error, :invalid_payload} ->
        Response.error(conn, :bad_request, "invalid_payload", "Invalid vault setup payload")

      {:error, changeset} ->
        Response.error(conn, :unprocessable_entity, "validation_failed", "Invalid vault setup", %{
          errors: errors_on(changeset)
        })
    end
  end

  @doc """
  POST /api/ext/v1/password-manager/entries
  """
  def create(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.get(params, "entry", params)

    case Payloads.decode_encrypted_entry_params(attrs) do
      {:ok, attrs} ->
        case PasswordManager.create_entry(user.id, attrs) do
          {:ok, entry} ->
            Response.created(conn, %{entry: format_entry(entry)})

          {:error, :vault_not_configured} ->
            Response.error(
              conn,
              :precondition_required,
              "vault_not_configured",
              "Vault is not configured"
            )

          {:error, changeset} ->
            Response.error(conn, :unprocessable_entity, "validation_failed", "Invalid entry", %{
              errors: errors_on(changeset)
            })
        end

      {:error, :invalid_payload} ->
        Response.error(conn, :bad_request, "invalid_payload", "Invalid entry payload")
    end
  end

  @doc """
  GET /api/ext/v1/password-manager/entries/:id
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, entry_id} <- parse_id(id),
         {:ok, entry} <- PasswordManager.get_entry_ciphertext(user.id, entry_id) do
      Response.ok(conn, %{entry: format_entry(entry, include_ciphertext: true)})
    else
      {:error, :bad_request} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid entry id")

      {:error, :not_found} ->
        Response.error(conn, :not_found, "not_found", "Entry not found")
    end
  end

  @doc """
  DELETE /api/ext/v1/password-manager/entries/:id
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, entry_id} <- parse_id(id),
         {:ok, _entry} <- PasswordManager.delete_entry(user.id, entry_id) do
      Response.ok(conn, %{message: "Entry deleted"})
    else
      {:error, :bad_request} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid entry id")

      {:error, :not_found} ->
        Response.error(conn, :not_found, "not_found", "Entry not found")
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

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_, default), do: default

  defp parse_non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> default
    end
  end

  defp parse_non_negative_int(_, default), do: default

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

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
