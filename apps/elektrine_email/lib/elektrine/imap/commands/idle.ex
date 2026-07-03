defmodule Elektrine.IMAP.Commands.Idle do
  @moduledoc "IMAP IDLE command and its notification loop."

  require Logger

  alias Elektrine.Constants
  alias Elektrine.IMAP.Commands.Shared
  alias Elektrine.IMAP.{Helpers, IdleTracker, RecentState}
  alias Elektrine.Mail.Socket

  defp max_idle_per_ip, do: Constants.imap_max_idle_per_ip()
  defp idle_timeout_ms, do: Constants.imap_idle_timeout_ms()

  def handle_idle(tag, state) do
    idle_count = IdleTracker.count_connections(state)

    if idle_count >= max_idle_per_ip() do
      Helpers.send_response(state.socket, "#{tag} NO Too many IDLE connections from your IP")
      {:continue, state}
    else
      session_id = Helpers.generate_session_id()
      IdleTracker.track_connection(state, state.client_ip, session_id)
      Process.put(:imap_idle_session_id, session_id)
      mailbox_topic = "mailbox:#{state.mailbox.id}"
      Phoenix.PubSub.subscribe(Elektrine.PubSub, mailbox_topic)
      Helpers.send_response(state.socket, "+ idling")
      idle_start = System.monotonic_time(:millisecond)
      idle_state = %{state | idle_start: idle_start, idle_session_id: session_id}

      try do
        result =
          case idle_loop(idle_state, idle_start) do
            {:revoked, reason, new_state} ->
              Helpers.send_response(state.socket, Shared.revocation_bye(reason))
              {:logout, new_state}

            {:done, new_state} ->
              Helpers.send_response(state.socket, "#{tag} OK IDLE terminated")
              {:continue, %{new_state | idle_start: nil, idle_session_id: nil}}

            {:timeout, new_state} ->
              Helpers.send_response(state.socket, "#{tag} OK IDLE terminated (timeout)")
              {:continue, %{new_state | idle_start: nil, idle_session_id: nil}}
          end

        result
      after
        Phoenix.PubSub.unsubscribe(Elektrine.PubSub, mailbox_topic)
        IdleTracker.untrack_connection(state, state.client_ip, session_id)
        Process.delete(:imap_idle_session_id)
      end
    end
  end

  defp idle_loop(state, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    timeout = max(1000, idle_timeout_ms() - elapsed)
    Socket.setopts(state.socket, active: :once)

    receive do
      {:app_password_revoked, _user_id, _app_password_id} ->
        Socket.setopts(state.socket, active: false)
        {:revoked, :app_password_revoked, state}

      {:mail_auth_changed, _user_id} ->
        Socket.setopts(state.socket, active: false)
        {:revoked, :two_factor_requires_app_password, state}

      {:tcp, _socket, data} ->
        command = data |> to_string() |> String.trim() |> String.upcase()
        Socket.setopts(state.socket, active: false)

        if command == "DONE" do
          {:done, state}
        else
          idle_loop(state, start_time)
        end

      {:ssl, _socket, data} ->
        command = data |> to_string() |> String.trim() |> String.upcase()
        Socket.setopts(state.socket, active: false)

        if command == "DONE" do
          {:done, state}
        else
          idle_loop(state, start_time)
        end

      {:tcp_closed, _socket} ->
        {:done, state}

      {:ssl_closed, _socket} ->
        {:done, state}

      {:tcp_error, _socket, reason} ->
        Logger.error("IDLE socket error: #{inspect(reason)}")
        {:done, state}

      {:ssl_error, _socket, reason} ->
        Logger.error("IDLE socket error: #{inspect(reason)}")
        {:done, state}

      {:new_email, message} ->
        if RecentState.should_notify_idle_folder_update?(message, state.selected_folder) do
          {:ok, fresh_messages} =
            Shared.load_folder_messages(state.mailbox, state.selected_folder)

          recent_message_ids = RecentState.merge_recent_message_ids(state, fresh_messages)

          if length(fresh_messages) != length(state.messages) do
            Helpers.send_response(state.socket, "* #{length(fresh_messages)} EXISTS")

            Helpers.send_response(
              state.socket,
              "* #{RecentState.count_recent_messages(fresh_messages, recent_message_ids)} RECENT"
            )
          end

          updated_state = %{
            state
            | messages: fresh_messages,
              recent_message_ids: recent_message_ids
          }

          idle_loop(updated_state, start_time)
        else
          idle_loop(state, start_time)
        end
    after
      timeout ->
        Socket.setopts(state.socket, active: false)
        {:timeout, state}
    end
  end
end
