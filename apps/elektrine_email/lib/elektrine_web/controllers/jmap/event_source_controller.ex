defmodule ElektrineWeb.JMAP.EventSourceController do
  @moduledoc """
  Minimal JMAP EventSource endpoint.

  It streams current state immediately and then publishes future state bumps from
  the mailbox's JMAP topic. This is enough for clients that use EventSource for
  push resync hints without requiring a separate websocket stack.
  """
  use ElektrineEmailWeb, :controller

  import Plug.Conn

  alias Elektrine.Email
  alias Elektrine.JMAP

  @supported_types ~w(Mailbox Email Thread EmailSubmission)
  @default_ping_ms 30_000

  def eventsource(conn, params) do
    user = conn.assigns[:current_user]
    account_id = conn.assigns[:jmap_account_id]
    mailbox = Email.get_user_mailbox(user.id)
    requested_types = requested_types(Map.get(params, "types"))
    closeafter = Map.get(params, "closeafter", "state")
    ping_ms = ping_interval(Map.get(params, "ping"))

    Phoenix.PubSub.subscribe(Elektrine.PubSub, "jmap:#{mailbox.id}")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case send_state_event(conn, mailbox.id, account_id, requested_types) do
      {:ok, conn} ->
        if closeafter == "state" do
          conn
        else
          stream_events(conn, mailbox.id, account_id, requested_types, ping_ms)
        end

      {:error, :closed} ->
        conn
    end
  end

  defp stream_events(conn, mailbox_id, account_id, requested_types, ping_ms) do
    receive do
      {:jmap_state_change, changed_types} ->
        relevant_types = Enum.filter(changed_types, &(&1 in requested_types))

        if relevant_types == [] do
          stream_events(conn, mailbox_id, account_id, requested_types, ping_ms)
        else
          case send_state_event(conn, mailbox_id, account_id, relevant_types) do
            {:ok, conn} ->
              stream_events(conn, mailbox_id, account_id, requested_types, ping_ms)

            {:error, :closed} ->
              conn
          end
        end
    after
      ping_ms ->
        case chunk(conn, ": ping\n\n") do
          {:ok, conn} ->
            stream_events(conn, mailbox_id, account_id, requested_types, ping_ms)

          {:error, :closed} ->
            conn
        end
    end
  end

  defp send_state_event(conn, mailbox_id, account_id, requested_types) do
    payload =
      [
        "id: ",
        event_id(mailbox_id, requested_types),
        "\n",
        "event: state\n",
        "data: ",
        Jason.encode!(JMAP.state_change(mailbox_id, account_id, requested_types)),
        "\n\n"
      ]

    chunk(conn, payload)
  end

  defp event_id(mailbox_id, requested_types) do
    requested_types =
      requested_types
      |> Enum.sort()
      |> Enum.join(",")

    "#{JMAP.get_session_state(mailbox_id)}:#{requested_types}"
  end

  defp requested_types(nil), do: @supported_types
  defp requested_types("*"), do: @supported_types

  defp requested_types(types) when is_binary(types) do
    types
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 in @supported_types))
    |> case do
      [] -> @supported_types
      requested -> requested
    end
  end

  defp requested_types(_), do: @supported_types

  defp ping_interval(nil), do: @default_ping_ms

  defp ping_interval(value) do
    case Integer.parse(to_string(value)) do
      {seconds, ""} when seconds > 0 ->
        min(seconds, 300) * 1_000

      _ ->
        @default_ping_ms
    end
  end
end
