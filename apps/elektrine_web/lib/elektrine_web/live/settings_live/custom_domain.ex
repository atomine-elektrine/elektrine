defmodule ElektrineWeb.SettingsLive.CustomDomain do
  @moduledoc """
  Redirects to the main settings page with custom-domain tab.
  Custom domain management has been integrated into UserSettingsLive.
  """

  use ElektrineWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, push_navigate(socket, to: ~p"/settings?tab=custom-domain")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-screen">
      <.spinner size="lg" />
    </div>
    """
  end
end
