defmodule Elektrine.IMAP.Commands do
  @moduledoc "IMAP command processing and handling.\nImplements all IMAP4rev1 commands and extensions (IDLE, UIDPLUS, etc).\n"
  require Logger
  alias Elektrine.Domains
  alias Elektrine.IMAP.{AppendParser, Helpers, IdleTracker, RecentState}
  alias Elektrine.IMAP.Commands.Append
  alias Elektrine.IMAP.Commands.Auth
  alias Elektrine.IMAP.Commands.Idle
  alias Elektrine.IMAP.Commands.Mailbox
  alias Elektrine.IMAP.Commands.Message
  alias Elektrine.IMAP.Commands.Search
  alias Elektrine.IMAP.Commands.Shared

  @authenticated_capabilities [
    "IMAP4rev1",
    "UIDPLUS",
    "IDLE",
    "UNSELECT",
    "NAMESPACE",
    "ID",
    "ENABLE",
    "MOVE",
    "SPECIAL-USE",
    "LIST-EXTENDED",
    "LIST-STATUS",
    "LITERAL+",
    "CHILDREN",
    "XLIST",
    "QUOTA",
    "STATUS=SIZE"
  ]
  @doc false
  def capability_string(state \\ :not_authenticated)

  def capability_string(%{state: state_name} = state) do
    state_name
    |> capability_list(state)
    |> Enum.join(" ")
  end

  def capability_string(:not_authenticated) do
    capability_list(:not_authenticated, %{})
    |> Enum.join(" ")
  end

  def capability_string(_state) do
    Enum.join(@authenticated_capabilities, " ")
  end

  defp capability_list(:not_authenticated, state) do
    auth_caps =
      if Auth.auth_allowed?(state) do
        ["AUTH=PLAIN", "AUTH=LOGIN"]
      else
        []
      end

    starttls_caps =
      if Auth.starttls_available?(state) do
        ["STARTTLS"]
      else
        []
      end

    auth_caps ++ starttls_caps ++ @authenticated_capabilities
  end

  defp capability_list(_state, _context), do: @authenticated_capabilities

  @doc "Process IMAP command"
  def process_command(tag, cmd, args, state) do
    case mail_auth_revoked_reason(state) do
      nil ->
        process_valid_command(tag, cmd, args, state)

      reason ->
        Helpers.send_response(state.socket, Shared.revocation_bye(reason))
        {:logout, state}
    end
  end

  defp process_valid_command(tag, cmd, args, state) do
    case String.upcase(cmd) do
      "CAPABILITY" ->
        handle_capability(tag, state)

      "NOOP" ->
        handle_noop_any_state(tag, state)

      "LOGOUT" ->
        handle_logout(tag, state)

      "ID" ->
        handle_id(tag, args, state)

      "STARTTLS" when state.state == :not_authenticated ->
        Auth.handle_starttls(tag, state)

      "AUTHENTICATE" when state.state == :not_authenticated ->
        Auth.handle_authenticate(tag, args, state)

      "LOGIN" when state.state == :not_authenticated ->
        Auth.handle_login(tag, args, state)

      "SELECT" when state.state in [:authenticated, :selected] ->
        Mailbox.handle_select(tag, args, state)

      "EXAMINE" when state.state in [:authenticated, :selected] ->
        Mailbox.handle_examine(tag, args, state)

      "LIST" when state.state in [:authenticated, :selected] ->
        Mailbox.handle_list(tag, args, state)

      "LSUB" when state.state in [:authenticated, :selected] ->
        Mailbox.handle_lsub(tag, args, state)

      "XLIST" when state.state in [:authenticated, :selected] ->
        Mailbox.handle_xlist(tag, args, state)

      "SUBSCRIBE" when state.state in [:authenticated, :selected] ->
        Mailbox.handle_subscribe(tag, args, state)

      "UNSUBSCRIBE" when state.state in [:authenticated, :selected] ->
        Mailbox.handle_unsubscribe(tag, args, state)

      "NAMESPACE" when state.state in [:authenticated, :selected] ->
        handle_namespace(tag, state)

      "ENABLE" when state.state in [:authenticated, :selected] ->
        handle_enable(tag, args, state)

      "CREATE" when state.state in [:authenticated, :selected] ->
        Mailbox.handle_create(tag, args, state)

      "DELETE" when state.state in [:authenticated, :selected] ->
        Mailbox.handle_delete(tag, args, state)

      "RENAME" when state.state in [:authenticated, :selected] ->
        Mailbox.handle_rename(tag, args, state)

      "STATUS" when state.state in [:authenticated, :selected] ->
        Mailbox.handle_status(tag, args, state)

      "APPEND" when state.state in [:authenticated, :selected] ->
        Append.handle_append(tag, args, state)

      "GETQUOTAROOT" when state.state in [:authenticated, :selected] ->
        Mailbox.handle_getquotaroot(tag, args, state)

      "GETQUOTA" when state.state in [:authenticated, :selected] ->
        Mailbox.handle_getquota(tag, args, state)

      "UID" when state.state == :selected ->
        Message.handle_uid(tag, args, state)

      "SEARCH" when state.state == :selected ->
        Search.handle_search(tag, args, state)

      "SORT" when state.state == :selected ->
        Search.handle_sort(tag, args, state)

      "THREAD" when state.state == :selected ->
        Search.handle_thread(tag, args, state)

      "FETCH" when state.state == :selected ->
        Message.handle_fetch(tag, args, state)

      "COPY" when state.state == :selected ->
        Message.handle_copy(tag, args, state)

      "MOVE" when state.state == :selected ->
        Message.handle_move(tag, args, state)

      "STORE" when state.state == :selected ->
        Message.handle_store(tag, args, state)

      "EXPUNGE" when state.state == :selected ->
        Message.handle_expunge(tag, state)

      "CHECK" when state.state == :selected ->
        Message.handle_check(tag, state)

      "CLOSE" when state.state == :selected ->
        Message.handle_close(tag, state)

      "UNSELECT" when state.state == :selected ->
        Message.handle_unselect(tag, state)

      "IDLE" when state.state == :selected ->
        Idle.handle_idle(tag, state)

      _ ->
        handle_unrecognized(tag, cmd, state)
    end
  end

  defp mail_auth_revoked_reason(%{user: %{id: user_id}, auth_app_password_id: app_password_id})
       when is_integer(app_password_id) do
    if Elektrine.Accounts.app_password_exists?(app_password_id, user_id) do
      nil
    else
      :app_password_revoked
    end
  end

  defp mail_auth_revoked_reason(%{user: %{id: user_id}, auth_method: :account_password}) do
    if Elektrine.Accounts.get_user!(user_id).two_factor_enabled do
      :two_factor_requires_app_password
    end
  rescue
    Ecto.NoResultsError -> :two_factor_requires_app_password
  end

  defp mail_auth_revoked_reason(_state), do: nil

  defp handle_capability(tag, state) do
    Helpers.send_response(state.socket, "* CAPABILITY #{capability_string(state)}")
    Helpers.send_response(state.socket, "#{tag} OK CAPABILITY completed")
    {:continue, state}
  end

  defp handle_noop_any_state(tag, state) do
    if state.state == :selected && state.mailbox && state.selected_folder do
      {:ok, fresh_messages} = Shared.load_folder_messages(state.mailbox, state.selected_folder)
      recent_message_ids = RecentState.merge_recent_message_ids(state, fresh_messages)

      if length(fresh_messages) != length(state.messages) do
        Helpers.send_response(state.socket, "* #{length(fresh_messages)} EXISTS")

        Helpers.send_response(
          state.socket,
          "* #{RecentState.count_recent_messages(fresh_messages, recent_message_ids)} RECENT"
        )
      end

      Helpers.send_response(state.socket, "#{tag} OK NOOP completed")
      {:continue, %{state | messages: fresh_messages, recent_message_ids: recent_message_ids}}
    else
      Helpers.send_response(state.socket, "#{tag} OK NOOP completed")
      {:continue, state}
    end
  end

  defp handle_logout(tag, state) do
    Helpers.send_response(state.socket, "* BYE Logging out")
    Helpers.send_response(state.socket, "#{tag} OK LOGOUT completed")
    {:logout, state}
  end

  defp handle_namespace(tag, state) do
    Helpers.send_response(state.socket, "* NAMESPACE ((\"\" \"/\")) NIL NIL")
    Helpers.send_response(state.socket, "#{tag} OK NAMESPACE completed")
    {:continue, state}
  end

  defp handle_id(tag, _args, state) do
    Helpers.send_response(
      state.socket,
      "* ID (\"name\" \"Elektrine\" \"version\" \"1.0\" \"vendor\" \"Elektrine\" \"support-url\" \"#{Domains.public_base_url()}\")"
    )

    Helpers.send_response(state.socket, "#{tag} OK ID completed")
    {:continue, state}
  end

  defp handle_enable(tag, args, state) do
    extensions = String.split(args || "", " ") |> Enum.reject(&(&1 == ""))

    enabled =
      Enum.filter(extensions, fn ext -> String.upcase(ext) in ["UIDPLUS", "IDLE", "UNSELECT"] end)

    if enabled != [] do
      Helpers.send_response(state.socket, "* ENABLED #{Enum.join(enabled, " ")}")
    end

    Helpers.send_response(state.socket, "#{tag} OK ENABLE completed")
    {:continue, state}
  end

  defp handle_unrecognized(tag, cmd, state) do
    IdleTracker.track_invalid_command(state, state.client_ip, cmd)
    Logger.warning("IMAP unrecognized command from #{state.client_ip}: #{cmd}")
    Helpers.send_response(state.socket, "#{tag} BAD Command not recognized")
    {:continue, state}
  end

  def parse_email_data(data), do: AppendParser.parse_email_data(data)

  def extract_text_body(body, headers, message \\ nil),
    do: AppendParser.extract_text_body(body, headers, message)

  def extract_html_body(body, headers, message \\ nil),
    do: AppendParser.extract_html_body(body, headers, message)

  def extract_attachments(body, headers, message \\ nil),
    do: AppendParser.extract_attachments(body, headers, message)
end
