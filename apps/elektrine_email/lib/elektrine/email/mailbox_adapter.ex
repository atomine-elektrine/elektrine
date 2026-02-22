defmodule Elektrine.Email.MailboxAdapter do
  @moduledoc """
  Adapter module for mailbox operations.
  Temporary mailbox functionality has been removed for security.
  """

  alias Elektrine.Email.Mailbox
  alias Elektrine.Email.Message
  alias Elektrine.Repo
  import Ecto.Query

  @doc """
  Creates a message for a mailbox with routing validation.

  Options:
    - `pre_validated: true` - Skip routing validation (for Haraka emails already validated)
  """
  def create_message(attrs) do
    # Extract mailbox_id from attributes
    mailbox_id = Map.get(attrs, :mailbox_id) || Map.get(attrs, "mailbox_id")
    # Fix integer/string conversion - ensure mailbox_id is an integer
    mailbox_id = if is_binary(mailbox_id), do: String.to_integer(mailbox_id), else: mailbox_id

    # Check if already validated by caller (e.g., Haraka controller)
    pre_validated = Map.get(attrs, :pre_validated) || Map.get(attrs, "pre_validated") || false

    if pre_validated do
      # Skip validation - already validated by Haraka controller
      Elektrine.Email.create_message(attrs)
    else
      # FINAL VALIDATION: Before creating any message, verify email routing is correct
      case final_routing_validation(attrs, mailbox_id) do
        :ok ->
          # Validation passed, proceed with message creation
          Elektrine.Email.create_message(attrs)

        {:error, reason} ->
          require Logger
          Logger.error("FINAL ROUTING VALIDATION FAILED: #{reason}")
          Logger.error("Message attributes: #{inspect(attrs)}")
          {:error, :final_routing_validation_failed}
      end
    end
  end

  @doc """
  Gets a regular mailbox by ID.
  """
  def get_mailbox_internal(id) do
    case Repo.get(Mailbox, id) do
      %Mailbox{} = mailbox -> {:regular, mailbox}
      nil -> nil
    end
  end

  @doc """
  List messages for a regular mailbox.
  """
  def list_messages(mailbox_id, limit \\ 50, offset \\ 0) do
    Message
    |> where([m], m.mailbox_id == ^mailbox_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  # FINAL VALIDATION: Last chance to prevent email misrouting
  defp final_routing_validation(attrs, mailbox_id) do
    # Get the TO address from message attributes
    to_address = Map.get(attrs, :to) || Map.get(attrs, "to")

    # Get the mailbox email
    mailbox_email = get_mailbox_email(mailbox_id)

    case {to_address, mailbox_email} do
      {nil, _} ->
        {:error, "No TO address specified in message"}

      {_, nil} ->
        {:error, "Mailbox not found for ID: #{mailbox_id}"}

      {to, mailbox} ->
        # Extract and normalize email addresses
        to_clean = extract_clean_email_final(to)
        mailbox_clean = extract_clean_email_final(mailbox)

        if to_clean && mailbox_clean do
          # Normalize plus addressing
          to_normalized = normalize_plus_address_final(to_clean)
          mailbox_normalized = normalize_plus_address_final(mailbox_clean)

          # Check if they match (case insensitive)
          if String.downcase(to_normalized) == String.downcase(mailbox_normalized) do
            :ok
          else
            # Check local part matching for cross-domain support
            if check_local_part_match_final(to_clean, mailbox_clean) do
              :ok
            else
              # Check if TO address is a valid alias for this mailbox's user
              if check_alias_validation_final(to_clean, mailbox_id) do
                :ok
              else
                {:error, "TO address '#{to_clean}' does not match mailbox '#{mailbox_clean}'"}
              end
            end
          end
        else
          {:error, "Failed to extract clean email addresses - TO: #{to}, Mailbox: #{mailbox}"}
        end
    end
  end

  # Get mailbox email by ID
  defp get_mailbox_email(mailbox_id) do
    case get_mailbox_internal(mailbox_id) do
      {:regular, mailbox} -> mailbox.email
      nil -> nil
    end
  end

  # Extract clean email address (simplified version for final validation)
  defp extract_clean_email_final(email) when is_binary(email) do
    case Regex.run(~r/([^\s<>,]+@[^\s<>,]+)/, email) do
      [_, clean] -> String.trim(clean)
      _ -> nil
    end
  end

  defp extract_clean_email_final(_), do: nil

  # Normalize plus addressing (simplified version for final validation)
  defp normalize_plus_address_final(email) do
    case String.split(email, "@") do
      [local_part, domain] ->
        # Remove everything after + in local part
        clean_local = String.split(local_part, "+") |> hd()
        "#{clean_local}@#{domain}"

      _ ->
        email
    end
  end

  # Check if local parts match across supported domains
  defp check_local_part_match_final(email1, email2) do
    case {String.split(email1, "@"), String.split(email2, "@")} do
      {[local1, domain1], [local2, domain2]} ->
        # Get supported domains
        supported_domains =
          Application.get_env(:elektrine, :email)[:supported_domains] ||
            ["elektrine.com", "z.org"]

        # Both domains must be supported and local parts must match
        String.downcase(local1) == String.downcase(local2) &&
          domain1 in supported_domains &&
          domain2 in supported_domains

      _ ->
        false
    end
  end

  # Check if TO address is a valid alias for the mailbox's user
  defp check_alias_validation_final(to_address, mailbox_id) do
    # Get the user ID for this mailbox
    case get_mailbox_internal(mailbox_id) do
      {:regular, mailbox} ->
        # Use the existing email ownership verification which handles aliases
        case Elektrine.Email.verify_email_ownership(to_address, mailbox.user_id) do
          {:ok, _ownership_type} -> true
          {:error, _reason} -> false
        end

      nil ->
        false
    end
  end
end
