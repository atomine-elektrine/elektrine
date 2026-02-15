defmodule Elektrine.Email.Contacts do
  @moduledoc """
  Context for managing email contacts.
  """
  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Email.{Contact, ContactGroup}

  # ===== CONTACTS =====

  @doc """
  Lists all contacts for a user.
  """
  def list_contacts(user_id) do
    from(c in Contact,
      where: c.user_id == ^user_id,
      order_by: [asc: c.name],
      preload: [:group]
    )
    |> Repo.all()
  end

  @doc """
  Lists favorite contacts for a user.
  """
  def list_favorite_contacts(user_id) do
    from(c in Contact,
      where: c.user_id == ^user_id and c.favorite == true,
      order_by: [asc: c.name],
      preload: [:group]
    )
    |> Repo.all()
  end

  @doc """
  Searches contacts by name or email.
  """
  def search_contacts(user_id, query) when is_binary(query) do
    search_term = "%#{String.downcase(query)}%"

    from(c in Contact,
      where: c.user_id == ^user_id,
      where:
        fragment("LOWER(?) LIKE ?", c.name, ^search_term) or
          fragment("LOWER(?) LIKE ?", c.email, ^search_term),
      order_by: [desc: c.favorite, asc: c.name],
      limit: 10,
      preload: [:group]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single contact.
  """
  def get_contact!(id), do: Repo.get!(Contact, id)

  @doc """
  Gets a single contact by user_id and contact_id.
  Raises if not found or doesn't belong to user.
  """
  def get_contact!(user_id, id) do
    from(c in Contact,
      where: c.id == ^id and c.user_id == ^user_id
    )
    |> Repo.one!()
  end

  @doc """
  Gets a contact by user_id and email.
  """
  def get_contact_by_email(user_id, email) do
    Repo.get_by(Contact, user_id: user_id, email: String.downcase(email))
  end

  @doc """
  Creates a contact.
  """
  def create_contact(attrs) do
    %Contact{}
    |> Contact.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a contact.
  """
  def update_contact(%Contact{} = contact, attrs) do
    contact
    |> Contact.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a contact.
  """
  def delete_contact(%Contact{} = contact) do
    Repo.delete(contact)
  end

  @doc """
  Toggles favorite status for a contact.
  """
  def toggle_favorite(%Contact{} = contact) do
    contact
    |> Contact.changeset(%{favorite: !contact.favorite})
    |> Repo.update()
  end

  @doc """
  Auto-creates contact from email sender if not exists.
  """
  def auto_create_from_sender(user_id, from_email, from_name \\ nil) do
    email = extract_email(from_email)
    name = from_name || extract_name(from_email) || email

    case get_contact_by_email(user_id, email) do
      nil ->
        create_contact(%{
          user_id: user_id,
          name: name,
          email: email
        })

      contact ->
        {:ok, contact}
    end
  end

  # ===== CARDDAV FUNCTIONS =====

  @doc """
  Gets a contact by its CardDAV UID.
  """
  def get_contact_by_uid(user_id, uid) do
    Repo.get_by(Contact, user_id: user_id, uid: uid)
  end

  @doc """
  Creates a contact via CardDAV with full vCard support.
  """
  def create_contact_carddav(attrs) do
    %Contact{}
    |> Contact.carddav_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a contact via CardDAV with full vCard support.
  """
  def update_contact_carddav(%Contact{} = contact, attrs) do
    contact
    |> Contact.carddav_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Lists contacts modified since a given timestamp.
  Used for CardDAV sync.
  """
  def list_contacts_since(user_id, nil) do
    list_contacts(user_id)
  end

  def list_contacts_since(user_id, %DateTime{} = since) do
    from(c in Contact,
      where: c.user_id == ^user_id and c.updated_at > ^since,
      order_by: [asc: c.updated_at],
      preload: [:group]
    )
    |> Repo.all()
  end

  # ===== CONTACT GROUPS =====

  @doc """
  Lists all contact groups for a user.
  """
  def list_contact_groups(user_id) do
    from(g in ContactGroup,
      where: g.user_id == ^user_id,
      order_by: [asc: g.name]
    )
    |> Repo.all()
  end

  @doc """
  Gets a contact group by user_id and group_id.
  Raises if not found or doesn't belong to user.
  """
  def get_contact_group!(user_id, id) do
    from(g in ContactGroup,
      where: g.id == ^id and g.user_id == ^user_id
    )
    |> Repo.one!()
  end

  @doc """
  Creates a contact group.
  """
  def create_contact_group(attrs) do
    %ContactGroup{}
    |> ContactGroup.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a contact group.
  """
  def update_contact_group(%ContactGroup{} = group, attrs) do
    group
    |> ContactGroup.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a contact group (contacts in group will have group_id set to nil).
  """
  def delete_contact_group(%ContactGroup{} = group) do
    Repo.delete(group)
  end

  @doc """
  Get recent email recipients (from contacts + sent emails).
  Used for autocomplete in compose.
  """
  def get_recent_recipients(user_id, limit \\ 20) do
    import Ecto.Query

    # Get from contacts
    contacts =
      from(c in Contact,
        where: c.user_id == ^user_id,
        order_by: [desc: c.favorite, desc: c.updated_at],
        limit: ^limit,
        select: %{email: c.email, name: c.name, source: "contact"}
      )
      |> Repo.all()

    # Get from sent emails
    sent =
      from(m in Elektrine.Email.Message,
        join: mb in assoc(m, :mailbox),
        where: mb.user_id == ^user_id and m.status == "sent",
        where: not is_nil(m.to),
        order_by: [desc: m.inserted_at],
        limit: ^(limit * 2),
        select: m.to
      )
      |> Repo.all()
      |> Enum.flat_map(&extract_recipients/1)
      |> Enum.uniq()
      |> Enum.take(limit)
      |> Enum.map(fn email ->
        %{email: email, name: extract_name_from_email(email), source: "sent"}
      end)

    # Combine and deduplicate by email
    (contacts ++ sent)
    |> Enum.uniq_by(&String.downcase(&1.email))
    |> Enum.take(limit)
  end

  # ===== HELPERS =====

  defp extract_email(from) when is_binary(from) do
    case Regex.run(~r/<(.+?)>/, from) do
      [_, email] -> String.downcase(String.trim(email))
      _ -> String.downcase(String.trim(from))
    end
  end

  defp extract_name(from) when is_binary(from) do
    case Regex.run(~r/^(.+?)\s*<.+>$/, from) do
      [_, name] -> String.trim(name, "\"")
      _ -> nil
    end
  end

  defp extract_recipients(to_string) when is_binary(to_string) do
    to_string
    |> String.split([",", ";"])
    |> Enum.map(&String.trim/1)
    |> Enum.map(&extract_email/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_name_from_email(email) when is_binary(email) do
    case Regex.run(~r/^(.+?)\s*<.+>$/, email) do
      [_, name] -> String.trim(name, "\"")
      _ -> String.split(email, "@") |> List.first()
    end
  end
end
