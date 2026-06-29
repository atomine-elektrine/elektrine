defmodule ElektrineNerveWeb.API.NerveController do
  @moduledoc """
  External API controller for encrypted nerve entries.
  """

  use ElektrineNerveWeb, :controller

  alias Elektrine.Nerve
  alias Elektrine.Nerve.Payloads
  alias Elektrine.Vault
  alias ElektrineNerveWeb.API.Response

  @doc """
  GET /api/ext/v1/nerve/entries
  """
  def index(conn, params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], 50) |> min(100)
    offset = parse_non_negative_int(params["offset"], 0)

    all_entries = Nerve.list_entries(user.id)
    entries = all_entries |> Enum.drop(offset) |> Enum.take(limit)
    master = Vault.get(user.id)

    Response.ok(
      conn,
      %{
        entries: entries,
        # Nerve now unlocks with the account master password; the wrapped MDK is
        # the verifier (unwrap with the passphrase to derive the Nerve subkey).
        master_configured: not is_nil(master),
        master_wrapped_dek: master && master.wrapped_dek
      },
      %{pagination: %{limit: limit, offset: offset, total_count: length(all_entries)}}
    )
  end

  @doc """
  POST /api/ext/v1/nerve/setup

  Deprecated: Nerve no longer has its own passphrase. The master password is set
  up in account settings.
  """
  def setup(conn, _params) do
    Response.error(
      conn,
      :bad_request,
      "master_password_required",
      "Nerve now uses your account master password. Set it up at /account/security."
    )
  end

  @doc """
  DELETE /api/ext/v1/nerve
  """
  def delete_nerve(conn, _params) do
    user = conn.assigns.current_user

    {:ok, result} = Nerve.delete_nerve(user.id)

    Response.ok(conn, %{
      message: "Nerve entries deleted",
      deleted_entries: result.deleted_entries
    })
  end

  @doc """
  POST /api/ext/v1/nerve/entries
  """
  def create(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.get(params, "entry", params)

    case Payloads.decode_encrypted_entry_params(attrs) do
      {:ok, attrs} ->
        case Nerve.create_entry(user.id, attrs) do
          {:ok, entry} ->
            Response.created(conn, %{entry: format_entry(entry)})

          {:error, :nerve_not_configured} ->
            Response.error(
              conn,
              :precondition_required,
              "nerve_not_configured",
              "Nerve is not configured"
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
  PUT /api/ext/v1/nerve/entries/:id
  """
  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    attrs = Map.get(params, "entry", params)

    with {:ok, entry_id} <- parse_id(id),
         {:ok, attrs} <- Payloads.decode_encrypted_entry_params(attrs),
         {:ok, entry} <- Nerve.update_entry(user.id, entry_id, attrs) do
      Response.ok(conn, %{entry: format_entry(entry)})
    else
      {:error, :bad_request} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid entry id")

      {:error, :invalid_payload} ->
        Response.error(conn, :bad_request, "invalid_payload", "Invalid entry payload")

      {:error, :not_found} ->
        Response.error(conn, :not_found, "not_found", "Entry not found")

      {:error, changeset} ->
        Response.error(conn, :unprocessable_entity, "validation_failed", "Invalid entry", %{
          errors: errors_on(changeset)
        })
    end
  end

  @doc """
  GET /api/ext/v1/nerve/entries/:id
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, entry_id} <- parse_id(id),
         {:ok, entry} <- Nerve.get_entry_ciphertext(user.id, entry_id) do
      Response.ok(conn, %{entry: format_entry(entry, include_ciphertext: true)})
    else
      {:error, :bad_request} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid entry id")

      {:error, :not_found} ->
        Response.error(conn, :not_found, "not_found", "Entry not found")
    end
  end

  @doc """
  DELETE /api/ext/v1/nerve/entries/:id
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, entry_id} <- parse_id(id),
         {:ok, _entry} <- Nerve.delete_entry(user.id, entry_id) do
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
      encrypted_metadata: entry.encrypted_metadata,
      encrypted_password: if(include_ciphertext?, do: entry.encrypted_password, else: nil),
      encrypted_notes: if(include_ciphertext?, do: entry.encrypted_notes, else: nil),
      inserted_at: entry.inserted_at,
      updated_at: entry.updated_at
    }
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      interpolate_error(message, opts)
    end)
  end

  defp interpolate_error(message, opts) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
