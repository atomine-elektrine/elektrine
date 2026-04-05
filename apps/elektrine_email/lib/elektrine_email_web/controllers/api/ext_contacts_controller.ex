defmodule ElektrineEmailWeb.API.ExtContactsController do
  @moduledoc """
  External API controller for read-only address book access.
  """

  use ElektrineEmailWeb, :controller

  import Ecto.Query, warn: false

  alias Elektrine.Email.Contact
  alias Elektrine.Repo
  alias ElektrineWeb.API.Response

  @default_limit 20
  @max_limit 100

  @doc """
  GET /api/ext/v1/contacts
  """
  def index(conn, params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], @default_limit) |> min(@max_limit)
    offset = parse_non_negative_int(params["offset"], 0)
    search_query = normalize_search(params["q"])

    query = build_query(user.id, search_query)
    total_count = Repo.aggregate(query, :count, :id)

    contacts =
      query
      |> order_by([contact], desc: contact.favorite, asc: contact.name)
      |> preload([:group])
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()

    Response.ok(
      conn,
      %{contacts: Enum.map(contacts, &format_contact_summary/1)},
      %{
        pagination: %{limit: limit, offset: offset, total_count: total_count},
        filters: maybe_put_search(%{}, search_query)
      }
    )
  end

  @doc """
  GET /api/ext/v1/contacts/:id
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, contact_id} <- parse_id(id),
         contact when not is_nil(contact) <-
           from(contact in Contact,
             where: contact.user_id == ^user.id and contact.id == ^contact_id,
             preload: [:group]
           )
           |> Repo.one() do
      Response.ok(conn, %{contact: format_contact_detail(contact)})
    else
      {:error, :invalid_id} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid contact id")

      nil ->
        Response.error(conn, :not_found, "not_found", "Contact not found")
    end
  end

  defp build_query(user_id, nil) do
    from(contact in Contact, where: contact.user_id == ^user_id)
  end

  defp build_query(user_id, search_query) do
    pattern = "%" <> String.downcase(search_query) <> "%"

    from(contact in Contact,
      where: contact.user_id == ^user_id,
      where:
        fragment("LOWER(?) LIKE ?", contact.name, ^pattern) or
          fragment("LOWER(?) LIKE ?", contact.email, ^pattern)
    )
  end

  defp format_contact_summary(contact) do
    %{
      id: contact.id,
      uid: contact.uid,
      name: contact.name,
      email: contact.email,
      phone: contact.phone,
      organization: contact.organization,
      favorite: contact.favorite || false,
      group: format_group(contact.group),
      updated_at: contact.updated_at,
      inserted_at: contact.inserted_at
    }
  end

  defp format_contact_detail(contact) do
    format_contact_summary(contact)
    |> Map.merge(%{
      notes: contact.notes,
      formatted_name: contact.formatted_name,
      first_name: contact.first_name,
      middle_name: contact.middle_name,
      last_name: contact.last_name,
      nickname: contact.nickname,
      emails: contact.emails || [],
      phones: contact.phones || [],
      addresses: contact.addresses || [],
      urls: contact.urls || [],
      social_profiles: contact.social_profiles || [],
      birthday: contact.birthday,
      anniversary: contact.anniversary,
      title: contact.title,
      department: contact.department,
      role: contact.role,
      categories: contact.categories || [],
      etag: contact.etag,
      revision: contact.revision,
      vcard_data: contact.vcard_data
    })
  end

  defp format_group(nil), do: nil
  defp format_group(%Ecto.Association.NotLoaded{}), do: nil

  defp format_group(group) do
    %{
      id: group.id,
      name: group.name
    }
  end

  defp maybe_put_search(meta, nil), do: meta
  defp maybe_put_search(meta, search_query), do: Map.put(meta, :q, search_query)

  defp normalize_search(value) when is_binary(value) do
    trimmed = String.trim(value)
    if Elektrine.Strings.present?(trimmed), do: trimmed, else: nil
  end

  defp normalize_search(_value), do: nil

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_id(_value), do: {:error, :invalid_id}

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_value, default), do: default

  defp parse_non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> default
    end
  end

  defp parse_non_negative_int(_value, default), do: default
end
