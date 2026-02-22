defmodule ElektrineWeb.API.AliasController do
  @moduledoc """
  API controller for managing email aliases.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Email.Alias
  alias Elektrine.Email.Aliases

  action_fallback ElektrineWeb.FallbackController

  @doc """
  GET /api/aliases
  Lists all email aliases for the current user.
  """
  def index(conn, _params) do
    user = conn.assigns[:current_user]
    aliases = Aliases.list_aliases(user.id)

    conn
    |> put_status(:ok)
    |> json(%{aliases: Enum.map(aliases, &format_alias/1)})
  end

  @doc """
  GET /api/aliases/:id
  Gets a specific alias by ID.
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Aliases.get_alias(String.to_integer(id), user.id) do
      %Alias{} = alias_record ->
        conn
        |> put_status(:ok)
        |> json(%{alias: format_alias(alias_record)})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Alias not found"})
    end
  end

  @doc """
  POST /api/aliases
  Creates a new email alias.

  Params:
    - username: The local part of the alias email (required)
    - domain: The domain for the alias (elektrine.com or z.org) (required)
    - target_email: Optional forwarding target
    - description: Optional description
  """
  def create(conn, %{"alias" => alias_params}) do
    user = conn.assigns[:current_user]

    # Check alias limit (15 for non-admin users)
    existing_count = length(Aliases.list_aliases(user.id))
    max_aliases = if user.admin, do: :infinity, else: 15

    if max_aliases != :infinity && existing_count >= max_aliases do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Maximum alias limit reached (#{max_aliases} aliases)"})
    else
      attrs = %{
        username: Map.get(alias_params, "username"),
        domain: Map.get(alias_params, "domain", "elektrine.com"),
        user_id: user.id,
        target_email: Map.get(alias_params, "target_email"),
        description: Map.get(alias_params, "description")
      }

      case Aliases.create_alias(attrs) do
        {:ok, alias_record} ->
          conn
          |> put_status(:created)
          |> json(%{
            message: "Alias created successfully",
            alias: format_alias(alias_record)
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to create alias", errors: format_errors(changeset)})

        {:error, _reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to create alias"})
      end
    end
  end

  @doc """
  PUT /api/aliases/:id
  Updates an existing email alias.

  Params:
    - enabled: Enable/disable the alias
    - target_email: Update forwarding target
    - description: Update description
  """
  def update(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    case Aliases.get_alias(String.to_integer(id), user.id) do
      %Alias{} = alias_record ->
        # Build update attrs from allowed params
        update_attrs =
          %{}
          |> maybe_put(:enabled, params["alias"]["enabled"] || params["enabled"])
          |> maybe_put(:target_email, params["alias"]["target_email"] || params["target_email"])
          |> maybe_put(:description, params["alias"]["description"] || params["description"])

        case Aliases.update_alias(alias_record, update_attrs) do
          {:ok, updated_alias} ->
            conn
            |> put_status(:ok)
            |> json(%{
              message: "Alias updated successfully",
              alias: format_alias(updated_alias)
            })

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to update alias", errors: format_errors(changeset)})
        end

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Alias not found"})
    end
  end

  @doc """
  DELETE /api/aliases/:id
  Deletes an email alias.
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Aliases.get_alias(String.to_integer(id), user.id) do
      %Alias{} = alias_record ->
        case Aliases.delete_alias(alias_record) do
          {:ok, _deleted} ->
            conn
            |> put_status(:ok)
            |> json(%{message: "Alias deleted successfully"})

          {:error, _reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to delete alias"})
        end

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Alias not found"})
    end
  end

  # Private helpers

  defp format_alias(alias_record) do
    %{
      id: alias_record.id,
      alias_email: alias_record.alias_email,
      target_email: alias_record.target_email,
      description: alias_record.description,
      enabled: alias_record.enabled,
      inserted_at: alias_record.inserted_at,
      updated_at: alias_record.updated_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
