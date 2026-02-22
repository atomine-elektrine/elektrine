defmodule Elektrine.Email.SafeSenders do
  @moduledoc """
  Context module for managing safe/whitelisted email senders.
  """
  import Ecto.Query
  alias Elektrine.Email.SafeSender
  alias Elektrine.Repo

  @doc """
  Lists all safe senders for a user.
  """
  def list_safe_senders(user_id) do
    SafeSender
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a safe sender by ID for a user.
  """
  def get_safe_sender(id, user_id) do
    SafeSender
    |> where(id: ^id, user_id: ^user_id)
    |> Repo.one()
  end

  @doc """
  Creates a safe sender entry.
  """
  def create_safe_sender(attrs) do
    %SafeSender{}
    |> SafeSender.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Adds an email to safe senders.
  """
  def add_safe_email(user_id, email) do
    create_safe_sender(%{
      user_id: user_id,
      email: email
    })
  end

  @doc """
  Adds a domain to safe senders.
  """
  def add_safe_domain(user_id, domain) do
    create_safe_sender(%{
      user_id: user_id,
      domain: domain
    })
  end

  @doc """
  Updates a safe sender entry.
  """
  def update_safe_sender(%SafeSender{} = safe_sender, attrs) do
    safe_sender
    |> SafeSender.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a safe sender entry.
  """
  def delete_safe_sender(%SafeSender{} = safe_sender) do
    Repo.delete(safe_sender)
  end

  @doc """
  Removes an email from safe senders.
  """
  def remove_safe_email(user_id, email) do
    email = String.downcase(String.trim(email))

    SafeSender
    |> where(user_id: ^user_id, email: ^email)
    |> Repo.delete_all()
  end

  @doc """
  Removes a domain from safe senders.
  """
  def remove_safe_domain(user_id, domain) do
    domain = String.downcase(String.trim(domain))

    SafeSender
    |> where(user_id: ^user_id, domain: ^domain)
    |> Repo.delete_all()
  end

  @doc """
  Checks if an email address is from a safe sender.
  """
  def safe?(user_id, from_email) when is_binary(from_email) do
    email = extract_email(from_email) |> String.downcase()
    domain = extract_domain(email)

    query =
      from s in SafeSender,
        where: s.user_id == ^user_id,
        where: s.email == ^email or s.domain == ^domain,
        select: count(s.id)

    Repo.one(query) > 0
  end

  def safe?(_, _), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking safe sender changes.
  """
  def change_safe_sender(%SafeSender{} = safe_sender, attrs \\ %{}) do
    SafeSender.changeset(safe_sender, attrs)
  end

  # Extract just the email address from "Name <email@domain.com>" format
  defp extract_email(email_string) when is_binary(email_string) do
    case Regex.run(~r/<([^>]+)>/, email_string) do
      [_, email] -> String.trim(email)
      nil -> String.trim(email_string)
    end
  end

  defp extract_email(_), do: ""

  # Extract domain from email address
  defp extract_domain(email) do
    case String.split(email, "@") do
      [_, domain] -> domain
      _ -> ""
    end
  end
end
