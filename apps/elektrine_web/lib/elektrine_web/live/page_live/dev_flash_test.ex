defmodule ElektrineWeb.PageLive.DevFlashTest do
  use ElektrineWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Dev Flash Test")}
  end

  def handle_event("live_flash", %{"kind" => "error"}, socket) do
    {:noreply, put_flash(socket, :error, "LiveView error flash (dev test) at #{timestamp()}")}
  end

  def handle_event("live_flash", _params, socket) do
    {:noreply, put_flash(socket, :info, "LiveView info flash (dev test) at #{timestamp()}")}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <div class="container mx-auto px-4 py-10 max-w-3xl">
        <div class="card glass-card shadow-xl">
          <div class="card-body gap-6">
            <h1 class="text-3xl font-bold">Flash Test Page</h1>
            <p class="opacity-80">
              Use these controls to test Phoenix flash behavior from both LiveView and controller redirects.
            </p>

            <div class="divider my-0"></div>

            <section class="space-y-3">
              <h2 class="text-xl font-semibold">LiveView Flash</h2>
              <div class="flex flex-wrap gap-2">
                <button class="btn btn-success" phx-click="live_flash" phx-value-kind="info">
                  Trigger LiveView Info
                </button>
                <button class="btn btn-error" phx-click="live_flash" phx-value-kind="error">
                  Trigger LiveView Error
                </button>
              </div>
            </section>

            <section class="space-y-3">
              <h2 class="text-xl font-semibold">Controller Redirect Flash</h2>
              <div class="flex flex-wrap gap-2">
                <.link href={~p"/dev/flash-test/controller/info"} class="btn btn-success">
                  Trigger Controller Info
                </.link>
                <.link href={~p"/dev/flash-test/controller/error"} class="btn btn-error">
                  Trigger Controller Error
                </.link>
              </div>
            </section>

            <div class="divider my-0"></div>

            <p class="text-sm opacity-70">
              Flash messages render through the layout-level <code class="font-mono">flash_group</code> component.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
