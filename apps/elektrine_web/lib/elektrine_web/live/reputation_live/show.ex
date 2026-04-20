defmodule ElektrineWeb.ReputationLive.Show do
  use ElektrineWeb, :live_view

  alias Elektrine.{Accounts, Reputation}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_search_state(socket)}
  end

  @impl true
  def handle_params(%{"handle" => handle}, _uri, socket) do
    {:noreply, load_graph(socket, handle)}
  end

  def handle_params(%{"q" => query}, _uri, socket) do
    {:noreply, load_search(socket, query)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign_search_state(socket)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    cond do
      not Elektrine.Strings.present?(query) ->
        {:noreply, push_patch(socket, to: ~p"/reputation")}

      user = Accounts.get_user_by_username_or_handle(query) ->
        {:noreply, push_navigate(socket, to: ~p"/reputation/#{user.handle || user.username}")}

      true ->
        {:noreply, push_patch(socket, to: ~p"/reputation?q=#{query}")}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/reputation")}
  end

  defp assign_not_found(socket) do
    socket
    |> assign(:page_title, "Reputation Graph")
    |> assign(:subject_user, nil)
    |> assign(:reputation_graph, nil)
    |> assign(:private_graph, false)
    |> assign(:not_found, true)
    |> assign(:search_query, "")
    |> assign(:search_results, [])
    |> assign(:search_mode, false)
  end

  defp assign_search_state(socket) do
    socket
    |> assign(:page_title, "Reputation Graph")
    |> assign(:subject_user, nil)
    |> assign(:reputation_graph, nil)
    |> assign(:private_graph, false)
    |> assign(:not_found, false)
    |> assign(:search_query, "")
    |> assign(:search_results, [])
    |> assign(:search_mode, true)
  end

  defp load_search(socket, query) do
    query = String.trim(to_string(query || ""))

    socket
    |> assign_search_state()
    |> assign(:search_query, query)
    |> assign(:search_results, Reputation.search_public_users(query))
  end

  defp load_graph(socket, handle) do
    cond do
      invalid_handle?(handle) ->
        assign_not_found(socket)

      user = Accounts.get_user_by_username_or_handle(handle) ->
        case Accounts.can_view_profile?(user, socket.assigns[:current_user]) do
          {:ok, :allowed} ->
            graph = Reputation.build_public_graph(user, socket.assigns[:current_user])

            socket
            |> assign(:page_title, "Reputation Graph - @#{graph.subject.handle}")
            |> assign(:subject_user, user)
            |> assign(:reputation_graph, graph)
            |> assign(:private_graph, false)
            |> assign(:not_found, false)
            |> assign(:search_query, "")
            |> assign(:search_results, [])
            |> assign(:search_mode, false)

          {:error, _reason} ->
            socket
            |> assign(:page_title, "Reputation Graph")
            |> assign(:subject_user, user)
            |> assign(:reputation_graph, nil)
            |> assign(:private_graph, true)
            |> assign(:not_found, false)
            |> assign(:search_query, "")
            |> assign(:search_results, [])
            |> assign(:search_mode, false)
        end

      true ->
        assign_not_found(socket)
    end
  end

  defp invalid_handle?(handle) do
    !Elektrine.Strings.present?(handle) or String.length(handle) > 100 or
      String.match?(handle, ~r/[\x00-\x1f]/)
  end
end
