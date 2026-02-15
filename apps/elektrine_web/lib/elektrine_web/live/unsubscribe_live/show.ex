defmodule ElektrineWeb.UnsubscribeLive.Show do
  use ElektrineWeb, :live_view

  alias Elektrine.Email.Unsubscribes

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(%{"token" => token}, _session, socket) do
    case get_unsubscribe_info(token) do
      {:ok, info} ->
        {:ok,
         assign(socket,
           page_title: "Unsubscribe",
           token: token,
           email: info.email,
           list_id: info.list_id,
           valid_token: true
         )}

      {:error, :invalid_token} ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid or expired unsubscribe link")
         |> assign(
           page_title: "Unsubscribe",
           valid_token: false,
           token: nil,
           email: nil,
           list_id: nil
         )}
    end
  end

  def render(assigns) do
    ~H"""
    <div id="unsubscribe-card" phx-hook="GlassCard" class="card glass-card shadow-xl max-w-md mx-auto">
      <div class="card-body">
        <%= if @valid_token do %>
          <h1 class="text-center text-3xl font-bold mb-6">Unsubscribe</h1>

          <p class="text-center opacity-70 mb-6">
            Are you sure you want to unsubscribe <strong>{@email}</strong>
            from receiving emails{if @list_id, do: " from this mailing list", else: ""}?
          </p>

          <.form for={%{}} action={~p"/unsubscribe/confirm/#{@token}"} method="post">
            <div class="flex flex-col gap-4 w-full">
              <.button class="w-full btn-secondary">
                Unsubscribe
              </.button>

              <.link href={~p"/"} class="btn btn-ghost w-full">
                Cancel
              </.link>
            </div>
          </.form>
        <% else %>
          <h1 class="text-center text-3xl font-bold mb-6">Invalid Link</h1>
          <p class="text-center opacity-70 mb-6">
            This unsubscribe link is invalid or has expired.
          </p>
          <div class="text-center">
            <.link href={~p"/"} class="btn btn-primary">Return to Home</.link>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp get_unsubscribe_info(token) do
    Unsubscribes.verify_token(token)
  end
end
