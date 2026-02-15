defmodule ElektrineWeb.EmailLive.Operations.SearchOperations do
  @moduledoc """
  Handles search operations for email inbox.
  """

  import Phoenix.Component

  alias Elektrine.Email

  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    if String.trim(query) != "" do
      mailbox = socket.assigns.mailbox

      results = Email.search_messages(mailbox.id, query)

      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:search_results, results)
       |> assign(:messages, results.messages || [])
       |> assign(:searching, false)}
    else
      {:noreply,
       socket
       |> assign(:search_query, "")
       |> assign(:search_results, %{messages: [], total_count: 0})
       |> assign(:messages, [])
       |> assign(:searching, false)}
    end
  end
end
