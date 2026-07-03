defmodule Elektrine.IMAP.Commands.Search do
  @moduledoc "IMAP SEARCH, SORT, and THREAD commands plus their UID variants."

  alias Elektrine.IMAP.Helpers

  def handle_search(tag, args, state) do
    criteria = String.upcase(args || "ALL")
    max_sequence = length(state.messages)

    matching_sequence_numbers =
      state.messages
      |> Enum.with_index(1)
      |> Enum.filter(fn {msg, sequence_number} ->
        message_matches_search?(msg, criteria, state, sequence_number, max_sequence)
      end)
      |> Enum.map(fn {_msg, seq_num} -> seq_num end)

    seq_list = Enum.join(matching_sequence_numbers, " ")
    Helpers.send_response(state.socket, "* SEARCH #{seq_list}")
    Helpers.send_response(state.socket, "#{tag} OK SEARCH completed")
    {:continue, state}
  end

  def handle_uid_search(tag, args, state) do
    criteria = String.upcase(args || "ALL")
    max_sequence = length(state.messages)

    matching_uids =
      state.messages
      |> Enum.with_index(1)
      |> Enum.filter(fn {msg, sequence_number} ->
        message_matches_search?(msg, criteria, state, sequence_number, max_sequence)
      end)
      |> Enum.map(fn {msg, _sequence_number} -> msg.id end)

    uid_list = Enum.join(matching_uids, " ")
    Helpers.send_response(state.socket, "* SEARCH #{uid_list}")
    Helpers.send_response(state.socket, "#{tag} OK UID SEARCH completed")
    {:continue, state}
  end

  def handle_sort(tag, args, state) do
    case parse_sort_args(args) do
      {:ok, sort_criteria, _charset, search_criteria} ->
        max_sequence = length(state.messages)

        matching =
          state.messages
          |> Enum.with_index(1)
          |> Enum.filter(fn {msg, sequence_number} ->
            Helpers.matches_search_criteria?(msg, search_criteria, sequence_number, max_sequence)
          end)

        sorted = sort_messages(matching, sort_criteria)
        uids = Enum.map_join(sorted, " ", fn {msg, _idx} -> msg.id end)
        Helpers.send_response(state.socket, "* SORT #{uids}")
        Helpers.send_response(state.socket, "#{tag} OK SORT completed")

      {:error, _} ->
        uids = Enum.map_join(state.messages, " ", & &1.id)
        Helpers.send_response(state.socket, "* SORT #{uids}")
        Helpers.send_response(state.socket, "#{tag} OK SORT completed")
    end

    {:continue, state}
  end

  def handle_uid_sort(tag, args, state) do
    case parse_sort_args(args) do
      {:ok, sort_criteria, _charset, search_criteria} ->
        max_sequence = length(state.messages)

        matching =
          state.messages
          |> Enum.with_index(1)
          |> Enum.filter(fn {msg, sequence_number} ->
            Helpers.matches_search_criteria?(msg, search_criteria, sequence_number, max_sequence)
          end)

        sorted = sort_messages(matching, sort_criteria)
        uids = Enum.map_join(sorted, " ", fn {msg, _idx} -> msg.id end)
        Helpers.send_response(state.socket, "* SORT #{uids}")
        Helpers.send_response(state.socket, "#{tag} OK UID SORT completed")

      {:error, _} ->
        uids = Enum.map_join(state.messages, " ", & &1.id)
        Helpers.send_response(state.socket, "* SORT #{uids}")
        Helpers.send_response(state.socket, "#{tag} OK UID SORT completed")
    end

    {:continue, state}
  end

  def handle_thread(tag, _args, state) do
    threads = thread_sequence_response(state.messages)

    if threads == "" do
      Helpers.send_response(state.socket, "* THREAD")
    else
      Helpers.send_response(state.socket, "* THREAD #{threads}")
    end

    Helpers.send_response(state.socket, "#{tag} OK THREAD completed")
    {:continue, state}
  end

  def handle_uid_thread(tag, _args, state) do
    threads = thread_uid_response(state.messages)

    if threads == "" do
      Helpers.send_response(state.socket, "* THREAD")
    else
      Helpers.send_response(state.socket, "* THREAD #{threads}")
    end

    Helpers.send_response(state.socket, "#{tag} OK UID THREAD completed")
    {:continue, state}
  end

  defp thread_sequence_response(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.map_join("", fn {_msg, seq_num} -> "(#{seq_num})" end)
  end

  defp thread_uid_response(messages) do
    Enum.map_join(messages, "", fn msg -> "(#{msg.id})" end)
  end

  defp parse_sort_args(nil) do
    {:error, :missing_args}
  end

  defp parse_sort_args(args) do
    case Regex.run(~r/\(([^)]+)\)\s+(\S+)\s*(.*)/i, args) do
      [_, criteria, charset, search] ->
        {:ok, String.split(criteria), charset, String.upcase(search || "ALL")}

      _ ->
        {:error, :invalid_format}
    end
  end

  defp sort_messages(messages, criteria) do
    Enum.sort_by(messages, fn {msg, _idx} ->
      Enum.map(criteria, fn crit ->
        case String.upcase(crit) do
          "DATE" -> msg.inserted_at
          "REVERSE" -> nil
          "FROM" -> msg.from || ""
          "TO" -> msg.to || ""
          "SUBJECT" -> msg.subject || ""
          "SIZE" -> byte_size(Map.get(msg, :text_body) || "")
          "ARRIVAL" -> msg.inserted_at
          _ -> nil
        end
      end)
    end)
  end

  defp message_matches_search?(msg, criteria, state, sequence_number, max_sequence) do
    criteria_upper = String.upcase(criteria)

    cond do
      criteria_upper == "RECENT" ->
        MapSet.member?(Map.get(state, :recent_message_ids, MapSet.new()), msg.id)

      criteria_upper == "NEW" ->
        MapSet.member?(Map.get(state, :recent_message_ids, MapSet.new()), msg.id) and not msg.read

      criteria_upper == "OLD" ->
        not MapSet.member?(Map.get(state, :recent_message_ids, MapSet.new()), msg.id)

      true ->
        Helpers.matches_search_criteria?(msg, criteria, sequence_number, max_sequence)
    end
  end
end
