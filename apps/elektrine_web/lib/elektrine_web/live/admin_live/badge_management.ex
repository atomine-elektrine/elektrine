defmodule ElektrineWeb.AdminLive.BadgeManagement do
  use ElektrineWeb, :live_view
  alias Elektrine.{Accounts, Profiles}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Badge Management")
     |> assign(:search_query, "")
     |> assign(:selected_user, nil)
     |> assign(:user_badges, [])
     |> assign(:search_results, [])}
  end

  @impl true
  def handle_event("search_user", %{"query" => query}, socket) do
    results =
      if String.length(query) >= 2 do
        search_all_users(query)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:search_results, results)}
  end

  def handle_event("select_user", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)
    user = Accounts.get_user!(user_id)
    badges = Profiles.list_user_badges(user_id)

    {:noreply,
     socket
     |> assign(:selected_user, user)
     |> assign(:user_badges, badges)
     |> assign(:search_results, [])}
  end

  def handle_event("grant_badge", %{"user_id" => user_id, "badge_type" => badge_type}, socket) do
    user_id = String.to_integer(user_id)

    attrs = %{
      user_id: user_id,
      badge_type: badge_type,
      granted_by_id: socket.assigns.current_user.id,
      badge_text: get_badge_text(badge_type),
      badge_color: get_badge_color(badge_type),
      badge_icon: get_badge_icon(badge_type),
      tooltip: get_badge_tooltip(badge_type)
    }

    case Profiles.create_badge(attrs) do
      {:ok, _badge} ->
        # Reload badges
        badges = Profiles.list_user_badges(user_id)

        {:noreply,
         socket
         |> assign(:user_badges, badges)
         |> put_flash(:info, "Badge granted successfully!")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to grant badge")}
    end
  end

  def handle_event("revoke_badge", %{"badge_id" => badge_id}, socket) do
    badge_id = String.to_integer(badge_id)

    case Profiles.delete_badge(badge_id) do
      {:ok, _} ->
        # Reload badges
        badges =
          if socket.assigns.selected_user do
            Profiles.list_user_badges(socket.assigns.selected_user.id)
          else
            []
          end

        {:noreply,
         socket
         |> assign(:user_badges, badges)
         |> put_flash(:info, "Badge revoked successfully!")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke badge")}
    end
  end

  defp search_all_users(query) do
    import Ecto.Query

    safe_query = String.replace(query, ~r/[%_]/, "")
    query_term = "%#{String.downcase(safe_query)}%"

    from(u in Accounts.User,
      where:
        fragment("LOWER(?) LIKE ?", u.username, ^query_term) or
          fragment("LOWER(?) LIKE ?", u.handle, ^query_term),
      order_by: [asc: u.username],
      limit: 10
    )
    |> Elektrine.Repo.all()
  end

  defp get_badge_text("staff"), do: "Staff"
  defp get_badge_text("verified"), do: "Verified"
  defp get_badge_text("supporter"), do: "Supporter"
  defp get_badge_text("developer"), do: "Developer"
  defp get_badge_text("admin"), do: "Admin"
  defp get_badge_text("moderator"), do: "Moderator"
  defp get_badge_text("contributor"), do: "Contributor"
  defp get_badge_text("beta_tester"), do: "Beta Tester"
  defp get_badge_text(_), do: "Custom"

  defp get_badge_color("staff"), do: "#22d3ee"
  defp get_badge_color("verified"), do: "#22c55e"
  defp get_badge_color("supporter"), do: "#f59e0b"
  defp get_badge_color("developer"), do: "#3b82f6"
  defp get_badge_color("admin"), do: "#dc2626"
  defp get_badge_color("moderator"), do: "#8b5cf6"
  defp get_badge_color("contributor"), do: "#06b6d4"
  defp get_badge_color("beta_tester"), do: "#ec4899"
  defp get_badge_color(_), do: "#6b7280"

  defp get_badge_icon("staff"), do: nil
  defp get_badge_icon("verified"), do: nil
  defp get_badge_icon("supporter"), do: nil
  defp get_badge_icon("developer"), do: nil
  defp get_badge_icon("admin"), do: nil
  defp get_badge_icon("moderator"), do: nil
  defp get_badge_icon("contributor"), do: nil
  defp get_badge_icon("beta_tester"), do: nil
  defp get_badge_icon(_), do: nil

  defp get_badge_tooltip("staff"), do: "Elektrine Staff Member"
  defp get_badge_tooltip("verified"), do: "Verified user"
  defp get_badge_tooltip("supporter"), do: "Platform supporter"
  defp get_badge_tooltip("developer"), do: "Developer"
  defp get_badge_tooltip("admin"), do: "Administrator"
  defp get_badge_tooltip("moderator"), do: "Moderator"
  defp get_badge_tooltip("contributor"), do: "Active contributor"
  defp get_badge_tooltip("beta_tester"), do: "Beta tester"
  defp get_badge_tooltip(_), do: nil

  defp hex_to_rgb("#" <> hex) do
    {r, ""} = Integer.parse(String.slice(hex, 0..1), 16)
    {g, ""} = Integer.parse(String.slice(hex, 2..3), 16)
    {b, ""} = Integer.parse(String.slice(hex, 4..5), 16)
    {r, g, b}
  end

  # Default purple
  defp hex_to_rgb(_hex), do: {139, 92, 246}
end
