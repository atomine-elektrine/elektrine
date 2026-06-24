defmodule ElektrineEmailWeb.EmailLive.Operations.SelectionOperations do
  @moduledoc """
  Handles message selection operations for email inbox.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  def handle_event("toggle_message_selection", %{"message_id" => message_id}, socket) do
    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        selected_messages = socket.assigns.selected_messages

        updated_selected =
          if message_id in selected_messages do
            List.delete(selected_messages, message_id)
          else
            [message_id | selected_messages]
          end

        select_all = length(updated_selected) == length(socket.assigns.messages)

        {:noreply,
         socket
         |> assign(:selected_messages, updated_selected)
         |> assign(:select_all, select_all)
         |> push_event("update_checkboxes", %{
           selected_ids: updated_selected,
           select_all: select_all
         })}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("select_all_messages", _params, socket) do
    if socket.assigns.select_all do
      # If all are selected, deselect all
      {:noreply,
       socket
       |> assign(:selected_messages, [])
       |> assign(:select_all, false)
       |> push_event("update_checkboxes", %{
         selected_ids: [],
         select_all: false
       })}
    else
      # If not all are selected, select all
      all_message_ids = Enum.map(socket.assigns.messages, & &1.id)

      {:noreply,
       socket
       |> assign(:selected_messages, all_message_ids)
       |> assign(:select_all, true)
       |> push_event("update_checkboxes", %{
         selected_ids: all_message_ids,
         select_all: true
       })}
    end
  end

  def handle_event("deselect_all_messages", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_messages, [])
     |> assign(:select_all, false)
     |> push_event("update_checkboxes", %{
       selected_ids: [],
       select_all: false
     })}
  end

  def handle_event("toggle_message_selection_on_shift", %{"message_id" => _message_id}, socket) do
    # This is handled by JavaScript for shift-click functionality
    # Just return without changes
    {:noreply, socket}
  end

  defp parse_positive_int(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end
end
