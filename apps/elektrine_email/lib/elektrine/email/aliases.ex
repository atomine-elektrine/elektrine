defmodule Elektrine.Email.Aliases do
  @moduledoc """
  Email alias management.
  Handles creation, retrieval, updates, and resolution of email aliases.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Ecto.Multi
  alias Elektrine.Email.Alias

  @doc """
  Returns the list of email aliases for a user.
  """
  def list_aliases(user_id) do
    Alias
    |> where(user_id: ^user_id)
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single alias by ID for a specific user.
  """
  def get_alias(id, user_id) do
    Alias
    |> where(id: ^id, user_id: ^user_id)
    |> Repo.one()
  end

  @doc """
  Gets an alias by alias email address.
  """
  def get_alias_by_email(alias_email) do
    # Normalize to lowercase for case-insensitive lookup
    lower_email = String.downcase(alias_email)

    # First try case-insensitive lookup
    case Alias |> where([a], fragment("lower(?)", a.alias_email) == ^lower_email) |> Repo.one() do
      %Alias{} = alias_record ->
        alias_record

      nil ->
        # Support plus addressing: username+tag@domain.com -> check username@domain.com
        case String.split(alias_email, "@") do
          [username_part, domain] when domain in ["elektrine.com", "z.org"] ->
            # Extract base username (before +)
            base_username = username_part |> String.split("+") |> List.first()
            base_email = "#{String.downcase(base_username)}@#{domain}"

            # Try lookup with base email (case-insensitive)
            Alias |> where([a], fragment("lower(?)", a.alias_email) == ^base_email) |> Repo.one()

          _ ->
            nil
        end
    end
  end

  @doc """
  Creates email aliases for both supported domains (elektrine.com and z.org).
  Takes a username and user_id, automatically creates aliases for both domains.
  """
  def create_alias(attrs \\ %{}) do
    # Check if domain is specified for single-domain creation
    case attrs do
      %{username: username, domain: domain, user_id: user_id}
      when is_binary(username) and is_binary(domain) and is_integer(user_id) ->
        create_single_domain_alias(username, domain, user_id, attrs)

      %{"username" => username, "domain" => domain, "user_id" => user_id}
      when is_binary(username) and is_binary(domain) ->
        create_single_domain_alias(username, domain, String.to_integer(user_id), attrs)

      # Legacy dual-domain creation (for backwards compatibility)
      %{username: username, user_id: user_id} when is_binary(username) and is_integer(user_id) ->
        create_dual_domain_aliases(username, user_id, attrs)

      %{"username" => username, "user_id" => user_id} when is_binary(username) ->
        create_dual_domain_aliases(username, String.to_integer(user_id), attrs)

      # Legacy single alias creation (for backwards compatibility)
      _ ->
        create_single_alias(attrs)
    end
  end

  # Create alias for a single specified domain
  defp create_single_domain_alias(username, domain, user_id, attrs) do
    target_email = attrs[:target_email] || attrs["target_email"] || ""
    description = attrs[:description] || attrs["description"] || ""

    alias_attrs = %{
      alias_email: "#{username}@#{domain}",
      target_email: target_email,
      description: description,
      user_id: user_id,
      enabled: true
    }

    result =
      %Alias{}
      |> Alias.changeset(alias_attrs)
      |> Repo.insert()

    case result do
      {:ok, alias} ->
        # Invalidate alias cache for this user
        Elektrine.Email.Cached.invalidate_aliases(user_id)
        {:ok, alias}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Create aliases for both domains (legacy, kept for backwards compatibility)
  defp create_dual_domain_aliases(username, user_id, attrs) do
    domains = [alias_elektrine: "elektrine.com", alias_zorg: "z.org"]
    target_email = attrs[:target_email] || attrs["target_email"] || ""
    description = attrs[:description] || attrs["description"] || ""

    multi =
      Enum.reduce(domains, Multi.new(), fn {operation, domain}, acc ->
        alias_attrs = %{
          alias_email: "#{username}@#{domain}",
          target_email: target_email,
          description: description,
          user_id: user_id,
          enabled: true
        }

        Multi.insert(acc, operation, Alias.changeset(%Alias{}, alias_attrs))
      end)

    case Repo.transaction(multi) do
      {:ok, %{alias_elektrine: alias1, alias_zorg: alias2}} ->
        Elektrine.Email.Cached.invalidate_aliases(user_id)
        {:ok, %{elektrine: alias1, zorg: alias2}}

      {:error, _operation, changeset, _changes} ->
        {:error, changeset}
    end
  end

  # Legacy single alias creation
  defp create_single_alias(attrs) do
    result =
      %Alias{}
      |> Alias.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, alias} ->
        # Invalidate alias cache for this user
        Elektrine.Email.Cached.invalidate_aliases(alias.user_id)
        {:ok, alias}

      error ->
        error
    end
  end

  @doc """
  Updates an email alias.
  """
  def update_alias(%Alias{} = alias, attrs) do
    result =
      alias
      |> Alias.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated_alias} ->
        # Invalidate alias cache for this user
        Elektrine.Email.Cached.invalidate_aliases(updated_alias.user_id)
        {:ok, updated_alias}

      error ->
        error
    end
  end

  @doc """
  Deletes an email alias.
  """
  def delete_alias(%Alias{} = alias) do
    import Ecto.Query
    user_id = alias.user_id

    # First, nullify alias_id in any forwarded_messages that reference this alias
    # This preserves the forwarding history for audit purposes
    from(fm in Elektrine.Email.ForwardedMessage, where: fm.alias_id == ^alias.id)
    |> Repo.update_all(set: [alias_id: nil])

    result = Repo.delete(alias)

    case result do
      {:ok, deleted_alias} ->
        # Invalidate alias cache for this user
        Elektrine.Email.Cached.invalidate_aliases(user_id)
        {:ok, deleted_alias}

      error ->
        error
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking alias changes.
  """
  def change_alias(%Alias{} = alias, attrs \\ %{}) do
    Alias.changeset(alias, attrs)
  end

  @doc """
  Checks if an email address is an alias and returns the target email.
  Returns nil if not an alias or if alias has no forwarding target.
  Returns :no_forward if alias exists but should deliver to main mailbox.
  """
  def resolve_alias(email) do
    case get_alias_by_email(email) do
      # Enabled alias with target email - forward it
      %Alias{enabled: true, target_email: target_email}
      when is_binary(target_email) and target_email != "" ->
        target_email

      # Disabled alias or alias without target - deliver to mailbox
      %Alias{enabled: false} ->
        :no_forward

      %Alias{target_email: target_email} when is_nil(target_email) or target_email == "" ->
        :no_forward

      # Not an alias
      nil ->
        nil
    end
  end
end
