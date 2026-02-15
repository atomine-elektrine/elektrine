defmodule Elektrine.Email.BlockedSenders do
  @moduledoc """
  Context module for managing blocked email senders.
  """
  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Email.BlockedSender

  @doc """
  Lists all blocked senders for a user.
  """
  def list_blocked_senders(user_id) do
    BlockedSender
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a blocked sender by ID for a user.
  """
  def get_blocked_sender(id, user_id) do
    BlockedSender
    |> where(id: ^id, user_id: ^user_id)
    |> Repo.one()
  end

  @doc """
  Creates a blocked sender entry.
  """
  def create_blocked_sender(attrs) do
    %BlockedSender{}
    |> BlockedSender.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Blocks an email address.
  """
  def block_email(user_id, email, reason \\ nil) do
    create_blocked_sender(%{
      user_id: user_id,
      email: email,
      reason: reason
    })
  end

  @doc """
  Blocks a domain.
  """
  def block_domain(user_id, domain, reason \\ nil) do
    create_blocked_sender(%{
      user_id: user_id,
      domain: domain,
      reason: reason
    })
  end

  @doc """
  Updates a blocked sender entry.
  """
  def update_blocked_sender(%BlockedSender{} = blocked_sender, attrs) do
    blocked_sender
    |> BlockedSender.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a blocked sender entry.
  """
  def delete_blocked_sender(%BlockedSender{} = blocked_sender) do
    Repo.delete(blocked_sender)
  end

  @doc """
  Unblocks an email address for a user.
  """
  def unblock_email(user_id, email) do
    email = String.downcase(String.trim(email))

    BlockedSender
    |> where(user_id: ^user_id, email: ^email)
    |> Repo.delete_all()
  end

  @doc """
  Unblocks a domain for a user.
  """
  def unblock_domain(user_id, domain) do
    domain = String.downcase(String.trim(domain))

    BlockedSender
    |> where(user_id: ^user_id, domain: ^domain)
    |> Repo.delete_all()
  end

  @doc """
  Checks if an email address is blocked for a user.
  """
  def is_blocked?(user_id, from_email) when is_binary(from_email) do
    email = extract_email(from_email) |> String.downcase()
    domain = extract_domain(email)

    query =
      from b in BlockedSender,
        where: b.user_id == ^user_id,
        where: b.email == ^email or b.domain == ^domain,
        select: count(b.id)

    Repo.one(query) > 0
  end

  def is_blocked?(_, _), do: false

  @doc """
  Gets the blocked entries that match a given email.
  """
  def get_matching_blocks(user_id, from_email) do
    email = extract_email(from_email) |> String.downcase()
    domain = extract_domain(email)

    BlockedSender
    |> where(user_id: ^user_id)
    |> where([b], b.email == ^email or b.domain == ^domain)
    |> Repo.all()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking blocked sender changes.
  """
  def change_blocked_sender(%BlockedSender{} = blocked_sender, attrs \\ %{}) do
    BlockedSender.changeset(blocked_sender, attrs)
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
