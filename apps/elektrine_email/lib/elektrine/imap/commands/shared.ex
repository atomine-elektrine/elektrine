defmodule Elektrine.IMAP.Commands.Shared do
  @moduledoc "Shared helpers used by multiple IMAP command handler modules."

  alias Elektrine.IMAP.{Folders, Helpers}

  def revocation_bye(:app_password_revoked), do: "* BYE App password revoked"

  def revocation_bye(:account_inactive), do: "* BYE Account inactive"

  def revocation_bye(:two_factor_requires_app_password),
    do: "* BYE 2FA now requires an app password"

  def load_folder_messages(mailbox, folder) do
    canonical_folder = Helpers.canonical_system_folder_name(folder)
    folder_normalized = String.upcase(canonical_folder)

    messages =
      case folder_normalized do
        "INBOX" -> Elektrine.Email.list_messages_for_imap(mailbox.id, :inbox)
        "SENT" -> Elektrine.Email.list_messages_for_imap(mailbox.id, :sent)
        "DRAFTS" -> Elektrine.Email.list_messages_for_imap(mailbox.id, :drafts)
        "TRASH" -> Elektrine.Email.list_messages_for_imap(mailbox.id, :trash)
        "SPAM" -> Elektrine.Email.list_messages_for_imap(mailbox.id, :spam)
        _ -> load_custom_folder_messages(mailbox, canonical_folder)
      end

    {:ok, messages}
  end

  defp load_custom_folder_messages(%{user_id: nil}, _folder_name) do
    []
  end

  defp load_custom_folder_messages(mailbox, folder_name) do
    case Folders.find_custom_folder_by_name(mailbox.user_id, folder_name) do
      nil -> []
      folder -> Elektrine.Email.list_messages_for_imap_custom_folder(mailbox.id, folder.id)
    end
  end
end
